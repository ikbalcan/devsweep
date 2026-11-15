import SwiftUI

/// Liquid Glass on macOS 26, regular materials before. Following Apple's guidance, glass is only
/// used for the control layer (floating bars, primary buttons), never for content like lists or cards.
extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Content surface: a quiet filled card with continuous corners (content never gets glass).
    func contentCard(cornerRadius: CGFloat = 18, tint: Color? = nil, emphasized: Bool = false) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill((tint ?? Color.primary).opacity(tint == nil ? 0.04 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(emphasized ? (tint ?? .accentColor) : Color.primary.opacity(0.08),
                              lineWidth: emphasized ? 1.5 : 1))
    }
}
