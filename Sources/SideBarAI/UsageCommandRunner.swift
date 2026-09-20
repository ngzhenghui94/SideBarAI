import Foundation
import Darwin

enum UsageCommandError: Error, Equatable, Sendable {
    case executableNotFound
    case commandFailed(Int32)
    case timedOut
    case invalidOutput
    case outputTooLarge
}

protocol UsageCommandRunning: Sendable {
    func run() async throws -> Data
}

struct ProcessUsageCommandRunner: UsageCommandRunning {
    private static let defaultTimeout: TimeInterval = 10
    private static let maximumTimeout: TimeInterval = 90
    private static let maximumOutputBytes = 1_048_576
    private static let outputChunkSize = 64 * 1024

    private let executableURL: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private let isolatedWorkingDirectory: Bool
    private let preventsApplicationLaunches: Bool

    init(
        executableName: String = "omp",
        arguments: [String] = ["usage", "--json"],
        executableURL: URL? = nil,
        timeout: TimeInterval = 10,
        isolatedWorkingDirectory: Bool = false,
        preventsApplicationLaunches: Bool = false
    ) {
        self.executableURL = executableURL ?? Self.resolveExecutable(named: executableName)
        self.arguments = arguments
        self.timeout = Self.normalizedTimeout(timeout)
        self.isolatedWorkingDirectory = isolatedWorkingDirectory
        self.preventsApplicationLaunches = preventsApplicationLaunches
    }

    static func resolveExecutable(named name: String) -> URL? {
        let fileManager = FileManager.default
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        if trimmedName.contains("/") {
            let url = URL(fileURLWithPath: trimmedName)
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        var directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent("bin").path,
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":", omittingEmptySubsequences: false).map(String.init))
        }

        var seenPaths = Set<String>()
        for directory in directories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(trimmedName).path
            guard seenPaths.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func run() async throws -> Data {
        guard let executableURL else {
            throw UsageCommandError.executableNotFound
        }

        // Print mode can still start OAuth. Enforce the background-only contract
        // at the OS boundary, including child processes and Launch Services.
        // A missing or rejected sandbox must fail; never retry unsandboxed.
        let launchURL: URL
        let launchArguments: [String]
        if preventsApplicationLaunches {
            let target = executableURL.resolvingSymlinksInPath().path
            launchURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            launchArguments = ["-p", Self.backgroundProfile, "-D", "EXECUTABLE=\(target)", target] + arguments
        } else {
            launchURL = executableURL
            launchArguments = arguments
        }
        let execution = try ProcessExecution(
            executableURL: launchURL,
            arguments: launchArguments,
            isolatedWorkingDirectory: isolatedWorkingDirectory,
            maximumOutputBytes: Self.maximumOutputBytes,
            outputChunkSize: Self.outputChunkSize
        )
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        try await execution.waitForResult()
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
                        } catch {
                            throw CancellationError()
                        }
                        execution.timeout()
                        throw UsageCommandError.timedOut
                    }

                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                    return result
                }
            }, onCancel: {
                execution.cancel()
            })
        } catch {
            execution.cancel()
            throw error
        }
    }

    // agy uses go-keyring, which reads macOS credentials through /usr/bin/security.
    // Keep that helper available without allowing open, shells, or other launchers.
    private static let backgroundProfile = """
    (version 1)
    (allow default)
    (deny process-exec (require-not (require-any
        (literal (param "EXECUTABLE"))
        (literal "/usr/bin/security"))))
    (deny mach-lookup (global-name-regex #"^com[.]apple[.]coreservices[.]launchservicesd"))
    (deny appleevent-send)
    """

    private static func normalizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite, timeout > 0 else { return defaultTimeout }
        return min(timeout, maximumTimeout)
    }

    private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        let rawValue = timeout * 1_000_000_000
        guard rawValue.isFinite, rawValue > 0 else { return 1 }
        return max(1, UInt64(rawValue))
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process: Process
    private let outputURL: URL
    private let outputHandle: FileHandle
    private let outputPipe: Pipe
    private let errorHandle: FileHandle
    private let inputHandle: FileHandle
    private let fileManager: FileManager
    private let workingDirectoryURL: URL?
    private let maximumOutputBytes: Int
    private let outputChunkSize: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Data, Error>?
    private var readerTask: Task<Void, Never>?
    private var outputBytes = 0
    private var readerError: Error?
    private var requestedError: Error?
    private var terminationStatus: Int32?
    private var hasStarted = false
    private var readerFinished = false
    private var hasCompleted = false

    init(
        executableURL: URL,
        arguments: [String],
        isolatedWorkingDirectory: Bool,
        maximumOutputBytes: Int,
        outputChunkSize: Int
    ) throws {
        let fileManager = FileManager.default
        let workingDirectoryURL: URL?
        if isolatedWorkingDirectory {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("SideBarAI-usage-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                throw UsageCommandError.commandFailed(-1)
            }
            workingDirectoryURL = directory
        } else {
            workingDirectoryURL = nil
        }

        let outputURL = (workingDirectoryURL ?? fileManager.temporaryDirectory)
            .appendingPathComponent("SideBarAI-usage-\(UUID().uuidString).json")
        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            if let workingDirectoryURL { try? fileManager.removeItem(at: workingDirectoryURL) }
            throw UsageCommandError.commandFailed(-1)
        }

        let outputHandle: FileHandle
        let errorHandle: FileHandle
        let inputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
            inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        } catch {
            try? fileManager.removeItem(at: outputURL)
            if let workingDirectoryURL { try? fileManager.removeItem(at: workingDirectoryURL) }
            throw error
        }

        self.fileManager = fileManager
        self.outputURL = outputURL
        self.outputHandle = outputHandle
        self.outputPipe = Pipe()
        self.errorHandle = errorHandle
        self.inputHandle = inputHandle
        self.workingDirectoryURL = workingDirectoryURL
        self.maximumOutputBytes = maximumOutputBytes
        self.outputChunkSize = outputChunkSize

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectoryURL
        if let workingDirectoryURL {
            var environment = ProcessInfo.processInfo.environment
            environment["PWD"] = workingDirectoryURL.path
            environment.removeValue(forKey: "OLDPWD")
            process.environment = environment
        }
        process.standardInput = inputHandle
        process.standardOutput = outputPipe.fileHandleForWriting
        process.standardError = errorHandle
        self.process = process
    }

    deinit {
        readerTask?.cancel()
        terminateProcess()
        closeHandles()
        removeArtifacts()
    }

    func waitForResult() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation)
        }
    }

    func cancel() {
        requestTermination(with: CancellationError())
    }

    func timeout() {
        requestTermination(with: UsageCommandError.timedOut)
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !hasStarted else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        hasStarted = true
        self.continuation = continuation
        let wasCancelled = requestedError != nil
        lock.unlock()

        if wasCancelled {
            lock.lock()
            terminationStatus = -1
            readerFinished = true
            lock.unlock()
            finishIfReady()
            return
        }

        process.terminationHandler = { [weak self] process in
            self?.processTerminated(status: process.terminationStatus)
        }
        startReader()

        do {
            try process.run()
        } catch {
            failToStart(with: error)
            return
        }

        lock.lock()
        let shouldTerminate = requestedError != nil
        lock.unlock()
        if shouldTerminate {
            terminateProcess()
        }
    }

    private func startReader() {
        readerTask = Task.detached(priority: nil) { [self] in
            readOutput()
        }
    }

    private func readOutput() {
        var readError: Error?
        while true {
            do {
                guard let chunk = try outputPipe.fileHandleForReading.read(upToCount: outputChunkSize), !chunk.isEmpty else {
                    break
                }
                guard append(chunk) else { break }
            } catch {
                readError = error
                break
            }
        }
        readerFinished(with: readError)
    }

    private func append(_ chunk: Data) -> Bool {
        lock.lock()
        guard !hasCompleted, requestedError == nil else {
            lock.unlock()
            return false
        }

        let remaining = maximumOutputBytes - outputBytes
        if chunk.count > remaining {
            if remaining > 0 {
                do {
                    try outputHandle.write(contentsOf: Data(chunk.prefix(remaining)))
                    outputBytes += remaining
                } catch {
                    readerError = error
                }
            }
            if requestedError == nil {
                requestedError = UsageCommandError.outputTooLarge
            }
            lock.unlock()
            terminateProcess()
            closeOutputReader()
            return false
        }

        do {
            try outputHandle.write(contentsOf: chunk)
            outputBytes += chunk.count
            lock.unlock()
            return true
        } catch {
            readerError = error
            lock.unlock()
            terminateProcess()
            closeOutputReader()
            return false
        }
    }

    private func readerFinished(with error: Error?) {
        lock.lock()
        if let error, readerError == nil, requestedError == nil {
            readerError = error
        }
        readerFinished = true
        lock.unlock()
        finishIfReady()
    }

    private func processTerminated(status: Int32) {
        lock.lock()
        terminationStatus = status
        lock.unlock()
        closeOutputWriter()
        finishIfReady()
    }

    private func failToStart(with error: Error) {
        lock.lock()
        if requestedError == nil { requestedError = error }
        terminationStatus = -1
        lock.unlock()
        closeOutputWriter()
        closeOutputReader()
        lock.lock()
        readerFinished = true
        lock.unlock()
        finishIfReady()
    }

    private func requestTermination(with error: Error) {
        lock.lock()
        if requestedError == nil { requestedError = error }
        let hasStarted = self.hasStarted
        let isRunning = process.isRunning
        lock.unlock()

        closeOutputReader()
        if hasStarted && isRunning {
            terminateProcess()
        }
    }

    private func terminateProcess() {
        let processIdentifier: pid_t
        lock.lock()
        let isRunning = process.isRunning
        processIdentifier = process.processIdentifier
        lock.unlock()

        guard isRunning else { return }
        process.terminate()
        if process.isRunning, processIdentifier > 0 {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func finishIfReady() {
        lock.lock()
        guard !hasCompleted, readerFinished, terminationStatus != nil else {
            lock.unlock()
            return
        }
        hasCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        let readerTask = self.readerTask
        self.readerTask = nil
        let requestedError = self.requestedError
        let readerError = self.readerError
        let status = self.terminationStatus
        lock.unlock()

        readerTask?.cancel()
        closeHandles()

        let result: Result<Data, Error>
        if let requestedError {
            result = .failure(requestedError)
        } else if let readerError {
            result = .failure(readerError)
        } else if let status, status == 0 {
            result = Result { try Data(contentsOf: outputURL) }
        } else {
            result = .failure(UsageCommandError.commandFailed(status ?? -1))
        }
        removeArtifacts()
        continuation?.resume(with: result)
    }

    private func closeOutputReader() {
        try? outputPipe.fileHandleForReading.close()
    }

    private func closeOutputWriter() {
        try? outputPipe.fileHandleForWriting.close()
    }

    private func closeHandles() {
        closeOutputReader()
        closeOutputWriter()
        try? outputHandle.close()
        try? errorHandle.close()
        try? inputHandle.close()
    }

    private func removeArtifacts() {
        try? fileManager.removeItem(at: outputURL)
        if let workingDirectoryURL {
            try? fileManager.removeItem(at: workingDirectoryURL)
        }
    }
}
