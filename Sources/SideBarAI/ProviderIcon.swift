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
        if let image = loadImage() {
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

    private func loadImage() -> NSImage? {
        guard let assetName,
              let url = Bundle.module.url(forResource: assetName, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private var assetName: String? {
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
