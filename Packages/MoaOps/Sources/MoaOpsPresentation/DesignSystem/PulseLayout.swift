import SwiftUI

/// Spacing tokens. 4 pt scale.
public enum PulseSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Corner radius tokens.
public enum PulseRadius {
    /// Small controls: fields, chips.
    public static let control: CGFloat = 12
    /// Cards and surfaces.
    public static let card: CGFloat = 16
    /// Large containers (transcript, sheets).
    public static let sheet: CGFloat = 22
}

extension View {
    /// Standard raised surface: raised fill + hairline + card radius.
    public func pulseCard(padding: CGFloat = PulseSpacing.md) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .fill(PulseColor.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                    .strokeBorder(PulseColor.hairline, lineWidth: 1)
            )
    }

    /// Subtle glow of the given color; the light signature of Pulse.
    public func pulseGlow(_ color: Color, radius: CGFloat = 18, opacity: Double = 0.35) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
    }

    /// Inline navigation title, cross-platform-safe
    /// (`navigationBarTitleDisplayMode` does not exist on macOS and the
    /// package also declares macOS 13).
    @ViewBuilder
    public func pulseInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Full-screen background: near-black base with a very faint warm halo
    /// at the top. Pins the dark color scheme.
    public func pulseScreenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    PulseColor.backgroundBase
                    RadialGradient(
                        colors: [PulseColor.ember.opacity(0.07), .clear],
                        center: UnitPoint(x: 0.5, y: -0.1),
                        startRadius: 0,
                        endRadius: 480
                    )
                }
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
    }
}
