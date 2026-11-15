import SwiftUI

/// Liquid Glass on macOS 26, regular materials before. Following Apple's guidance, glass is only
/// used for the control layer (floating bars, primary buttons), never for content like lists or cards.
extension View {
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: .capsule)
        } else {
            self.modifier(GlassFallback(shape: Capsule()))
        }
    }

    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.modifier(GlassFallback(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
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

/// Closest honest stand-in for Liquid Glass on macOS 14 and 15: a thin translucent material,
/// a light rim that is brighter at the top (where light would hit), a faint inner sheen and a
/// soft lifted shadow. There is no refraction; that only exists in the real material on macOS 26.
struct GlassFallback<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                // Sheen sits on top of the material, under the content.
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.10 : 0.35), .clear],
                                              startPoint: .top, endPoint: .center))
                }
            }
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.35 : 0.8),
                                                           .white.opacity(scheme == .dark ? 0.05 : 0.15),
                                                           .black.opacity(scheme == .dark ? 0.25 : 0.06)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.14), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}
