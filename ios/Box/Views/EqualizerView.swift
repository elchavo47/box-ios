import SwiftUI

/// 10 bantlı ekolayzer (Premium). Değişiklikler çalan şarkıya anında uygulanır.
struct EqualizerView: View {
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPremium = false

    private var unlocked: Bool { auth.has(.eq) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if !unlocked { lockCard }
                    VStack(spacing: 18) {
                        powerCard
                        graphCard
                        presets
                        boostCard
                        Text(L("Değişiklikler çalan şarkıya hemen uygulanır."))
                            .font(.footnote)
                            .foregroundColor(.boxTertiaryText)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!unlocked)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color.boxBackground.ignoresSafeArea())
            .navigationTitle(L("Ekolayzer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Sıfırla")) {
                        settings.eq.gains = EQPresetID.flat.gains
                        settings.eq.boost = 0
                        settings.eq.preset = EQPresetID.flat.rawValue
                        Haptics.tap()
                    }
                    .disabled(!unlocked || (settings.eq.gains.allSatisfy { $0 == 0 } && settings.eq.boost == 0))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Bitti")) { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $showPremium) { PremiumView() }
    }

    // MARK: Parçalar

    private var lockCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentSoft))
            Text(L("Ekolayzer Premium'a özel"))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            if auth.isPremium {
                Text(L("Ekolayzer hesabında kapalı."))
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
            } else {
                Text(L("10 bantlı ekolayzer, hazır ayarlar ve ses yükseltme Box Premium ile açılır."))
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
                    .multilineTextAlignment(.center)
                Button { showPremium = true } label: { Text(L("Premium'a geç")) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.boxSurface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.accent.opacity(0.35), lineWidth: 1))
    }

    private var powerCard: some View {
        Toggle(isOn: Binding(get: { settings.eq.enabled }, set: { settings.eq.enabled = $0; Haptics.tap() })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Ekolayzer")).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Text(currentPresetTitle).font(.footnote).foregroundColor(.boxSecondaryText)
            }
        }
        .tint(.accent)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.boxSurface))
        .opacity(unlocked ? 1 : 0.5)
    }

    private var currentPresetTitle: String {
        EQPresetID(rawValue: settings.eq.preset)?.title ?? L("Özel")
    }

    private var graphCard: some View {
        EQGraph(gains: Binding(
            get: { settings.eq.gains },
            set: { settings.eq.gains = $0; settings.eq.preset = "custom"; if !settings.eq.enabled { settings.eq.enabled = true } }
        ), active: settings.eq.enabled && unlocked)
        .frame(height: 280)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.boxSurface))
        .opacity(unlocked ? 1 : 0.5)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Hazır ayarlar"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.boxSecondaryText)
                .padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EQPresetID.allCases) { preset in
                        let on = settings.eq.preset == preset.rawValue
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                settings.eq.gains = preset.gains
                                settings.eq.preset = preset.rawValue
                                settings.eq.enabled = true
                            }
                            Haptics.tap()
                        } label: {
                            Text(preset.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(on ? .black : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(on ? Color.accent : Color.boxSurface2))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .opacity(unlocked ? 1 : 0.5)
    }

    private var boostCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("Ses yükseltme"), systemImage: "speaker.wave.3.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(settings.eq.boost == 0 ? L("Kapalı") : String(format: "+%.0f dB", settings.eq.boost))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(settings.eq.boost == 0 ? .boxSecondaryText : .accent)
            }
            Slider(value: Binding(
                get: { Double(settings.eq.boost) },
                set: {
                    settings.eq.boost = Float($0.rounded())
                    if !settings.eq.enabled { settings.eq.enabled = true }
                }
            ), in: Double(EQSettings.boostRange.lowerBound)...Double(EQSettings.boostRange.upperBound), step: 1)
            .tint(.accent)
            Text(L("Sessiz kayıtları ve kısık hoparlörleri güçlendirir. Taşmayı yumuşak sınırlayıcı önler; kulaklıkta sesi yüksek tutma."))
                .font(.footnote)
                .foregroundColor(.boxTertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.boxSurface))
        .opacity(unlocked ? 1 : 0.5)
    }
}

/// Bant sürgüleri ve yumuşak eğri. Parmağın dokunduğu bant sürüklenerek ayarlanır.
private struct EQGraph: View {
    @Binding var gains: [Float]
    var active: Bool
    @State private var dragging: Int?

    private let lo = EQSettings.range.lowerBound
    private let hi = EQSettings.range.upperBound
    private let labelHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let count = EQSettings.bandCount
            let width = geo.size.width
            let column = width / CGFloat(count)
            let top = labelHeight
            let height = geo.size.height - labelHeight * 2
            let x: (Int) -> CGFloat = { CGFloat($0) * column + column / 2 }
            let y: (Float) -> CGFloat = { top + height * CGFloat(1 - ($0 - lo) / (hi - lo)) }
            let points = (0..<count).map { CGPoint(x: x($0), y: y(gains[safe: $0] ?? 0)) }
            let zeroY = y(0)

            ZStack(alignment: .topLeading) {
                // 0 dB çizgisi
                Path { p in p.move(to: CGPoint(x: 0, y: zeroY)); p.addLine(to: CGPoint(x: width, y: zeroY)) }
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                // Eğri ve altı
                Self.curve(points, closeTo: zeroY, width: width)
                    .fill(LinearGradient(colors: [Color.accent.opacity(active ? 0.28 : 0.08), .clear], startPoint: .top, endPoint: .bottom))
                Self.curve(points, closeTo: nil, width: width)
                    .stroke(active ? Color.accent : Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(0..<count, id: \.self) { i in
                    let value = gains[safe: i] ?? 0
                    // Sürgü yolu
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 4, height: height)
                        .position(x: x(i), y: top + height / 2)
                    // Düğme
                    Circle()
                        .fill(active ? Color.white : Color.white.opacity(0.5))
                        .frame(width: dragging == i ? 24 : 18, height: dragging == i ? 24 : 18)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .position(x: x(i), y: y(value))
                        .animation(.easeOut(duration: 0.12), value: dragging)
                    // dB değeri
                    Text(value == 0 ? "0" : String(format: "%+.0f", value))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(dragging == i ? .accent : .boxSecondaryText)
                        .position(x: x(i), y: labelHeight / 2)
                    // Frekans
                    Text(EQSettings.label(for: EQSettings.frequencies[i]))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.boxTertiaryText)
                        .position(x: x(i), y: geo.size.height - labelHeight / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let band = dragging ?? min(max(Int(drag.startLocation.x / column), 0), count - 1)
                        if dragging == nil { dragging = band; Haptics.soft() }
                        let t = Float(1 - (drag.location.y - top) / height)
                        let raw = lo + min(max(t, 0), 1) * (hi - lo)
                        let snapped = (raw * 2).rounded() / 2
                        guard band < gains.count, gains[band] != snapped else { return }
                        if snapped.truncatingRemainder(dividingBy: 3) == 0 || snapped == 0 {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        var next = gains
                        next[band] = snapped
                        gains = next
                    }
                    .onEnded { _ in dragging = nil }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Ekolayzer"))
            .accessibilityValue(zip(EQSettings.frequencies, gains).map { "\(EQSettings.label(for: $0)) \(Int($1)) dB" }.joined(separator: ", "))
        }
    }

    /// Noktalardan geçen yumuşak eğri (orta noktalara ikinci dereceden eğriler).
    static func curve(_ points: [CGPoint], closeTo baseline: CGFloat?, width: CGFloat) -> Path {
        Path { p in
            guard let first = points.first, let last = points.last else { return }
            let start = CGPoint(x: 0, y: first.y)
            let end = CGPoint(x: width, y: last.y)
            if let baseline {
                p.move(to: CGPoint(x: 0, y: baseline))
                p.addLine(to: start)
            } else {
                p.move(to: start)
            }
            p.addLine(to: first)
            for i in 1..<points.count {
                let prev = points[i - 1], cur = points[i]
                let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                p.addQuadCurve(to: mid, control: prev)
                if i == points.count - 1 { p.addQuadCurve(to: cur, control: cur) }
            }
            p.addLine(to: end)
            if let baseline {
                p.addLine(to: CGPoint(x: width, y: baseline))
                p.closeSubpath()
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
