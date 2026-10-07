import AppKit
import SwiftUI

@MainActor
struct ProviderIcon: View {
    let provider: Provider
    let size: CGFloat
    let tint: Color

    init(provider: Provider, size: CGFloat = 18, tint: Color = .primary) {
        self.provider = provider
        self.size = size
        self.tint = tint
    }

    var body: some View {
        if let image = Self.templateImage(for: provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.systemImage)
                .font(.system(size: size * 0.78, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }

    private static let resourceBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("SideBarAI_SideBarAI.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return .module
    }()

    /// Template brand mark for the provider, or nil when only an SF Symbol exists.
    static func templateImage(for provider: Provider) -> NSImage? {
        guard let assetName = assetName(for: provider),
              let url = Self.resourceBundle.url(forResource: assetName, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private static func assetName(for provider: Provider) -> String? {
        switch provider {
        case .claude:
            "claude"
        case .chatgpt:
            "openai"
        case .antigravity:
            nil
        }
    }
}
