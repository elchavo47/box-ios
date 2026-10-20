import SwiftUI

// MARK: - Renkler

extension Color {
    /// Ana vurgu rengi (logodaki küpün üst yüzü).
    static let accent = Color(red: 0.243, green: 0.890, blue: 0.604)
    static let accentMid = Color(red: 0.129, green: 0.659, blue: 0.424)
    static let accentDeep = Color(red: 0.078, green: 0.478, blue: 0.302)
    static let accentSoft = Color(red: 0.243, green: 0.890, blue: 0.604).opacity(0.14)

    static let boxBackground = Color(red: 0.012, green: 0.012, blue: 0.016)
    static let boxSurface = Color(red: 0.078, green: 0.082, blue: 0.094)
    static let boxSurface2 = Color(red: 0.122, green: 0.129, blue: 0.145)
    static let boxStroke = Color.white.opacity(0.08)
    static let boxSecondaryText = Color(white: 0.64)
    static let boxTertiaryText = Color(white: 0.42)

    // Eski adlar (dosya yöneticisi gibi ekranlar için)
    static let neon = accent
    static let neonDim = accentSoft
    static let boxCard = boxSurface
    static let boxCardHighlight = boxSurface2
}

extension View {
    /// Ekran arka planı + mini oynatıcının altında son satırın kalmaması için boşluk.
    func boxScreenBackground() -> some View {
        modifier(ScreenBackground())
    }
}

private struct ScreenBackground: ViewModifier {
    @EnvironmentObject private var player: PlayerManager

    func body(content: Content) -> some View {
        let clearance: CGFloat = player.current == nil ? 16 : 96
        if #available(iOS 17.0, *) {
            content
                .contentMargins(.bottom, clearance, for: .scrollContent)
                .background(Color.boxBackground.ignoresSafeArea())
        } else {
            content.background(Color.boxBackground.ignoresSafeArea())
        }
    }
}

// MARK: - Logo

/// Box küp logosu (panel ile aynı çizim). Işık / gölge yok.
struct BoxMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 32
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 8) * s, y: (y - 8) * s) }

            var top = Path()
            top.move(to: p(24, 9)); top.addLine(to: p(38, 16.5)); top.addLine(to: p(24, 24)); top.addLine(to: p(10, 16.5)); top.closeSubpath()

            var left = Path()
            left.move(to: p(9, 20)); left.addLine(to: p(22, 27.2)); left.addLine(to: p(22, 39.5)); left.addLine(to: p(9, 32.3)); left.closeSubpath()

            var right = Path()
            right.move(to: p(39, 20)); right.addLine(to: p(26, 27.2)); right.addLine(to: p(26, 39.5)); right.addLine(to: p(39, 32.3)); right.closeSubpath()

            context.fill(top, with: .color(.accent))
            context.fill(left, with: .color(.accentMid))
            context.fill(right, with: .color(.accentDeep))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BoxWordmark: View {
    var markSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            BoxMark(size: markSize)
            Text("Box")
                .font(.system(size: markSize * 0.95, weight: .heavy))
                .tracking(-0.5)
                .foregroundColor(.white)
        }
    }
}

// MARK: - Buton stilleri

struct PrimaryButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline).weight(.semibold))
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .foregroundColor(filled ? .black : .white)
            .background(
                Capsule().fill(filled ? Color.white : Color.white.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

typealias NeonButtonStyle = PrimaryButtonStyle

struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline).weight(.medium))
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .foregroundColor(selected ? .black : .white)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.white : Color.white.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Basınca hafifçe küçülen, vurgusuz buton.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Biçimlendirme

enum Formatters {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func longDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) dk" }
        return "\(minutes / 60) sa \(minutes % 60) dk"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
