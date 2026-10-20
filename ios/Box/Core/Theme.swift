import SwiftUI

extension Color {
    static let neon = Color(red: 0.36, green: 1.0, blue: 0.18)
    static let neonDim = Color(red: 0.36, green: 1.0, blue: 0.18).opacity(0.18)
    static let boxBackground = Color(red: 0.027, green: 0.035, blue: 0.039)
    static let boxCard = Color(red: 0.075, green: 0.09, blue: 0.098)
    static let boxCardHighlight = Color(red: 0.11, green: 0.13, blue: 0.14)
    static let boxSecondaryText = Color(white: 0.62)
}

extension View {
    func neonGlow(radius: CGFloat = 10, opacity: Double = 0.7) -> some View {
        shadow(color: Color.neon.opacity(opacity), radius: radius)
    }

    func boxScreenBackground() -> some View {
        background(Color.boxBackground.ignoresSafeArea())
    }
}

struct NeonButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .foregroundColor(filled ? .black : .neon)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? Color.neon : Color.neonDim)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.neon.opacity(filled ? 0 : 0.5), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .foregroundColor(selected ? .black : .white)
            .background(
                Capsule().fill(selected ? Color.neon : Color.boxCardHighlight)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

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

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
