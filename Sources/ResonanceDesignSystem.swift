import SwiftUI
import UIKit

struct ResonancePalette {
    let backgroundGradient: [Color]
    let surfacePrimary: Color
    let surfaceSecondary: Color
    let elevatedSurface: Color
    let stroke: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let accentSoft: Color
    let shadow: Color
    let inputFill: Color
    let heroScrimTop: Color
    let heroScrimBottom: Color

    static func make(for colorScheme: ColorScheme, atmosphere: AtmosphereStyle? = nil) -> ResonancePalette {
        let style = atmosphere ?? .day
        let accent = style.accentColor

        switch colorScheme {
        case .dark:
            return ResonancePalette(
                backgroundGradient: style.darkBackgroundGradient,
                surfacePrimary: Color(uiColor: .secondarySystemBackground),
                surfaceSecondary: Color(uiColor: .tertiarySystemBackground),
                elevatedSurface: Color(uiColor: .systemBackground),
                stroke: Color(uiColor: .separator).opacity(0.42),
                primaryText: Color(uiColor: .label),
                secondaryText: Color(uiColor: .secondaryLabel),
                tertiaryText: Color(uiColor: .tertiaryLabel),
                accent: accent,
                accentSoft: accent.opacity(0.2),
                shadow: Color.black.opacity(0.38),
                inputFill: Color(uiColor: .tertiarySystemBackground),
                heroScrimTop: Color.black.opacity(0.18),
                heroScrimBottom: Color.black.opacity(0.82)
            )
        default:
            return ResonancePalette(
                backgroundGradient: style.lightBackgroundGradient,
                surfacePrimary: Color(uiColor: .systemBackground),
                surfaceSecondary: Color(uiColor: .secondarySystemBackground),
                elevatedSurface: Color(uiColor: .systemBackground),
                stroke: Color(uiColor: .separator).opacity(0.32),
                primaryText: Color(uiColor: .label),
                secondaryText: Color(uiColor: .secondaryLabel),
                tertiaryText: Color(uiColor: .tertiaryLabel),
                accent: accent,
                accentSoft: accent.opacity(0.12),
                shadow: Color.black.opacity(0.1),
                inputFill: Color(uiColor: .secondarySystemBackground),
                heroScrimTop: Color.black.opacity(0.08),
                heroScrimBottom: Color.black.opacity(0.56)
            )
        }
    }
}

private extension AtmosphereStyle {
    var accentColor: Color {
        switch self {
        case .dawn:
            return Color(red: 1.0, green: 0.55, blue: 0.48)
        case .day:
            return Color(red: 0.18, green: 0.45, blue: 0.95)
        case .dusk:
            return Color(red: 0.62, green: 0.34, blue: 0.92)
        case .night:
            return Color(red: 0.34, green: 0.56, blue: 0.96)
        }
    }

    var lightBackgroundGradient: [Color] {
        switch self {
        case .dawn:
            return [
                Color(red: 1.0, green: 0.94, blue: 0.92),
                Color(red: 0.99, green: 0.86, blue: 0.82),
                Color(red: 0.95, green: 0.9, blue: 1.0)
            ]
        case .day:
            return [
                Color(red: 0.92, green: 0.96, blue: 1.0),
                Color(red: 0.9, green: 0.93, blue: 0.99),
                Color(red: 0.98, green: 0.99, blue: 1.0)
            ]
        case .dusk:
            return [
                Color(red: 0.99, green: 0.91, blue: 0.85),
                Color(red: 0.91, green: 0.86, blue: 0.98),
                Color(red: 0.98, green: 0.96, blue: 0.95)
            ]
        case .night:
            return [
                Color(red: 0.9, green: 0.93, blue: 1.0),
                Color(red: 0.88, green: 0.9, blue: 0.98),
                Color(red: 0.96, green: 0.97, blue: 1.0)
            ]
        }
    }

    var darkBackgroundGradient: [Color] {
        switch self {
        case .dawn:
            return [
                Color(red: 0.17, green: 0.11, blue: 0.16),
                Color(red: 0.26, green: 0.14, blue: 0.17),
                Color(red: 0.11, green: 0.09, blue: 0.16)
            ]
        case .day:
            return [
                Color(red: 0.06, green: 0.1, blue: 0.18),
                Color(red: 0.08, green: 0.16, blue: 0.26),
                Color(red: 0.03, green: 0.07, blue: 0.13)
            ]
        case .dusk:
            return [
                Color(red: 0.16, green: 0.09, blue: 0.2),
                Color(red: 0.24, green: 0.12, blue: 0.23),
                Color(red: 0.08, green: 0.06, blue: 0.15)
            ]
        case .night:
            return [
                Color(red: 0.03, green: 0.05, blue: 0.1),
                Color(red: 0.08, green: 0.09, blue: 0.19),
                Color(red: 0.02, green: 0.03, blue: 0.08)
            ]
        }
    }
}

struct ResonanceGradientBackground: View {
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        LinearGradient(
            colors: palette.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(palette.accent.opacity(colorScheme == .dark ? 0.14 : 0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 40)
                .offset(x: 80, y: -80)
        }
        .ignoresSafeArea()
    }
}

struct ResonanceCard<Content: View>: View {
    var atmosphere: AtmosphereStyle? = nil
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(atmosphere: AtmosphereStyle? = nil, @ViewBuilder content: () -> Content) {
        self.atmosphere = atmosphere
        self.content = content()
    }

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfacePrimary, in: shape)
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(palette.stroke)
            }
            .shadow(color: palette.shadow, radius: 24, y: 12)
    }
}

struct ResonanceHeroScrim: View {
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        LinearGradient(
            colors: [palette.heroScrimTop, .clear, palette.heroScrimBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct ResonanceBadge: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)
        let resolvedTint = tint ?? palette.accent

        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.84)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(resolvedTint.opacity(colorScheme == .dark ? 0.22 : 0.14))
            )
            .foregroundStyle(resolvedTint)
    }
}

struct ResonanceStatTile: View {
    let title: String
    let value: String
    let symbol: String
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(palette.accent)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(palette.primaryText)
            Text(title)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.stroke)
        }
    }
}

struct ResonanceEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var atmosphere: AtmosphereStyle? = nil
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        ResonanceCard(atmosphere: atmosphere) {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 36))
                    .foregroundStyle(palette.accent)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                }

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        Button("設定を開く") {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ResonanceInputFieldModifier: ViewModifier {
    var atmosphere: AtmosphereStyle? = nil

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = ResonancePalette.make(for: colorScheme, atmosphere: atmosphere)

        content
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(palette.inputFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(palette.stroke)
            }
            .foregroundStyle(palette.primaryText)
    }
}

extension View {
    func resonanceInputField(atmosphere: AtmosphereStyle? = nil) -> some View {
        modifier(ResonanceInputFieldModifier(atmosphere: atmosphere))
    }
}

extension TimeInterval {
    var resonanceClockText: String {
        let totalSeconds = max(Int(rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
