import SwiftUI

/// The DevSweep mark: three disk layers in the tier colors (has data, re-download, rebuilds),
/// with the top layer being swept away into fragments. Drawn on a 1024 pt grid and scaled,
/// so the same view renders the app icon (scripts/icon) and in-app artwork.
struct LogoMark: View {
    var size: CGFloat = 128
    /// The full macOS icon with its squircle plate and shadow, or just the glyph.
    var withPlate = true

    static let green = Color(red: 0.204, green: 0.780, blue: 0.349)   // #34C759
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)      // #0A84FF
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)    // #FF9F0A

    var body: some View {
        let s = size / 1024
        ZStack {
            if withPlate {
                RoundedRectangle(cornerRadius: 186 * s, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.22, blue: 0.27),
                                                  Color(red: 0.08, green: 0.09, blue: 0.11)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 186 * s, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 5 * s)
                    )
                    .frame(width: 824 * s, height: 824 * s)
                    .shadow(color: .black.opacity(0.35), radius: 22 * s, y: 12 * s)
                    .position(x: 512 * s, y: 512 * s)
            }

            bar(Self.orange, x: 252, y: 688, width: 520, s: s)
            bar(Self.blue, x: 252, y: 560, width: 520, s: s)
            bar(Self.green, x: 252, y: 432, width: 292, s: s)

            // Fragments of the top layer, swept up and to the right.
            fragment(x: 612, y: 420, size: 76, opacity: 0.95, s: s)
            fragment(x: 706, y: 366, size: 56, opacity: 0.7, s: s)
            fragment(x: 778, y: 312, size: 38, opacity: 0.45, s: s)

            Image(systemName: "sparkle")
                .font(.system(size: 92 * s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .position(x: 770 * s, y: 222 * s)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func bar(_ color: Color, x: CGFloat, y: CGFloat, width: CGFloat, s: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(1), color.opacity(0.82)], startPoint: .top, endPoint: .bottom))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 3 * s))
            .frame(width: width * s, height: 96 * s)
            .position(x: (x + width / 2) * s, y: y * s)
    }

    private func fragment(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double, s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.34 * s, style: .continuous)
            .fill(Self.green.opacity(opacity))
            .frame(width: size * s, height: size * s)
            .rotationEffect(.degrees(-14))
            .position(x: x * s, y: y * s)
    }
}
