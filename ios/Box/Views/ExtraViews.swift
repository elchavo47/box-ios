import SwiftUI
import UIKit

// MARK: - İlk açılış tanıtımı

struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("folder.badge.plus", "Müziğini getir", "Dosyalar sekmesinden içe aktar, bilgisayardan Finder ile at ya da başka bir uygulamada \"Box ile aç\" de. Klasörlerin olduğu gibi kalır."),
        ("music.note.list", "Kitaplığını düzenle", "Çalma listeleri oluştur, sevdiklerini beğen, kapakları değiştir. Akıllı listeler en çok dinlediklerini kendiliğinden toplar."),
        ("moon.zzz.fill", "Sana göre", "Uyku zamanlayıcısı, şarkı sözleri, radyo, ekolayzer ve dinlediklerine göre öneriler. Hepsi Ayarlar'da."),
    ]

    var body: some View {
        ZStack {
            Color.boxBackground.ignoresSafeArea()
            LinearGradient(colors: [Color.accent.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    BoxWordmark(markSize: 24)
                    Spacer()
                    Button("Geç") { finish() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.boxSecondaryText)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        VStack(spacing: 22) {
                            Spacer()
                            ZStack {
                                Circle().fill(Color.accent.opacity(0.12)).frame(width: 150, height: 150)
                                Image(systemName: pages[index].icon)
                                    .font(.system(size: 60, weight: .semibold))
                                    .foregroundColor(.accent)
                            }
                            Text(pages[index].title)
                                .font(.system(size: 30, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(pages[index].text)
                                .font(.system(size: 17))
                                .foregroundColor(.boxSecondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Color.white : Color.white.opacity(0.25))
                            .frame(width: index == page ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.3), value: page)
                .padding(.bottom, 22)

                Button(page == pages.count - 1 ? "Başla" : "Devam") {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        finish()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func finish() {
        Haptics.success()
        withAnimation(.easeOut(duration: 0.3)) { settings.onboarded = true }
    }
}

// MARK: - Şarkı sözleri

struct LyricsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var service = LyricsService.shared
    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        ZStack {
            Color(player.artworkColor ?? UIColor(red: 0.12, green: 0.2, blue: 0.17, alpha: 1))
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if let track = player.current {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.url, size: 44, cornerRadius: 6, fallback: track.artworkFallback)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text(track.displayArtist).font(.system(size: 13)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                }

                if loading {
                    Spacer()
                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                    Spacer()
                } else if let lyrics {
                    LyricsBody(lyrics: lyrics, clock: player.clock) { player.seek(to: $0) }
                } else {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "text.quote").font(.system(size: 38)).foregroundColor(.white.opacity(0.6))
                        Text("Bu şarkının sözleri bulunamadı").font(.headline)
                        Text("Sözler lrclib.net'ten geliyor; az bilinen şarkılarda olmayabilir.")
                            .font(.subheadline).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .foregroundColor(.white)
        }
        .task(id: player.current?.id) {
            guard let track = player.current else { return }
            loading = true
            lyrics = await service.lyrics(for: track)
            loading = false
        }
    }
}

private struct LyricsBody: View {
    let lyrics: Lyrics
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void

    private var activeIndex: Int? {
        guard lyrics.synced else { return nil }
        let now = clock.currentTime + 0.3
        return lyrics.lines.lastIndex { ($0.time ?? 0) <= now }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(lyrics.lines) { line in
                        let active = line.id == activeIndex
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: lyrics.synced ? 26 : 20, weight: .bold))
                            .foregroundColor(.white.opacity(!lyrics.synced || active ? 1 : 0.38))
                            .scaleEffect(active ? 1.02 : 1, anchor: .leading)
                            .animation(.easeOut(duration: 0.25), value: active)
                            .id(line.id)
                            .onTapGesture {
                                if let time = line.time { onSeek(time) }
                            }
                    }
                    Text(lyrics.synced ? "Sözler: lrclib.net" : "Sözler: lrclib.net • senkron değil")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 20)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 30)
            }
            .onChange(of: activeIndex) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }
}

// MARK: - Bağlantı yok / hata

struct OfflineBanner: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        if !network.isOnline {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                VStack(alignment: .leading, spacing: 1) {
                    Text("İnternet yok").font(.system(size: 14, weight: .semibold))
                    Text("İndirdiklerin ve önbellektekiler çalmaya devam eder.").font(.system(size: 12)).opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.boxSurface2))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Akan arka plan

/// Kapağın renkleriyle yavaşça akan arka plan (Apple Music benzeri).
/// Hareketi Core Animation yürütür: ana iş parçacığında kare kare çizim yoktur, kasmaz.
/// Hareket azaltma açıksa durağan.
struct FlowingBackground: View {
    let colors: [Color]
    var playing: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowingLayerView(colors: colors.map { UIColor($0) }, moving: !reduceMotion)
            .overlay(
                LinearGradient(colors: [.clear, Color.black.opacity(0.35), Color.boxBackground.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct FlowingLayerView: UIViewRepresentable {
    let colors: [UIColor]
    let moving: Bool

    func makeUIView(context: Context) -> FlowingBackgroundView {
        FlowingBackgroundView()
    }

    func updateUIView(_ view: FlowingBackgroundView, context: Context) {
        view.apply(colors: colors)
        view.setMoving(moving)
    }
}

final class FlowingBackgroundView: UIView {
    private let base = CALayer()
    private var blobs: [CAGradientLayer] = []
    private var palette: [UIColor] = []
    private var moving = true
    private var observer: NSObjectProtocol?

    /// Her lekenin dolaştığı elips (oranlar) ve tur süresi.
    private let orbits: [(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, duration: CFTimeInterval, reversed: Bool)] = [
        (0.50, 0.28, 0.36, 0.20, 46, false),
        (0.42, 0.46, 0.30, 0.24, 61, true),
        (0.58, 0.22, 0.40, 0.16, 77, false),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(base)
        for _ in orbits {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(blob)
            blobs.append(blob)
        }
        apply(colors: [])
        // Uygulama arka plandan dönünce animasyonları yeniden başlat.
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartMotion(force: true) }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        let radius = max(bounds.width, bounds.height) * 0.75
        for (index, blob) in blobs.enumerated() {
            blob.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            blob.position = startPoint(index)
        }
        CATransaction.commit()
        restartMotion(force: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartMotion(force: false) }
    }

    func apply(colors: [UIColor]) {
        let next = colors.isEmpty ? [UIColor(red: 0.12, green: 0.24, blue: 0.19, alpha: 1)] : colors
        guard next != palette else { return }
        let animated = !palette.isEmpty
        palette = next
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.9)
        base.backgroundColor = next[0].withAlphaComponent(0.9).cgColor
        for (index, blob) in blobs.enumerated() {
            let color = next[index % next.count]
            blob.colors = [color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0).cgColor]
            blob.opacity = index < next.count ? 1 : 0
        }
        CATransaction.commit()
    }

    func setMoving(_ on: Bool) {
        guard on != moving else { return }
        moving = on
        restartMotion(force: true)
    }

    private func startPoint(_ index: Int) -> CGPoint {
        let orbit = orbits[index]
        return CGPoint(x: bounds.width * (orbit.cx + orbit.rx), y: bounds.height * orbit.cy)
    }

    private func restartMotion(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        for (index, blob) in blobs.enumerated() {
            if !moving {
                blob.removeAnimation(forKey: "flow")
                continue
            }
            if !force, blob.animation(forKey: "flow") != nil { continue }
            let orbit = orbits[index]
            let rect = CGRect(
                x: bounds.width * (orbit.cx - orbit.rx),
                y: bounds.height * (orbit.cy - orbit.ry),
                width: bounds.width * orbit.rx * 2,
                height: bounds.height * orbit.ry * 2
            )
            var path = UIBezierPath(ovalIn: rect)
            if orbit.reversed { path = path.reversing() }
            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.path = path.cgPath
            animation.calculationMode = .paced
            animation.duration = orbit.duration
            animation.repeatCount = .infinity
            animation.timeOffset = orbit.duration * Double(index) / 3
            animation.isRemovedOnCompletion = false
            blob.add(animation, forKey: "flow")
        }
    }
}

// MARK: - Görselleştirici

/// Müziğe göre oynayan çubuklar (ses akışından ölçülür).
struct VisualizerBars: View {
    @EnvironmentObject private var player: PlayerManager
    var height: CGFloat = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
            let levels = player.meter?.levels() ?? []
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<TapContext.bandCount * 2 - 1, id: \.self) { index in
                    // Ortadan iki yana yansıyan bantlar.
                    let band = abs(index - (TapContext.bandCount - 1))
                    let value = levels.indices.contains(band) ? CGFloat(levels[band]) : 0.08
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: max(4, height * (player.isPlaying ? value : 0.12)))
                }
            }
            .frame(height: height)
            .animation(.linear(duration: 1.0 / 30), value: levels)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Beğeni animasyonu

struct HeartButton: View {
    let liked: Bool
    var size: CGFloat = 24
    let action: () -> Void

    @State private var burst = false
    @State private var bounce = false

    var body: some View {
        Button {
            let willLike = !liked
            action()
            if willLike {
                Haptics.success()
                burst = false
                withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { bounce = true }
                withAnimation(.easeOut(duration: 0.55)) { burst = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = false }
                }
            } else {
                Haptics.tap()
            }
        } label: {
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) / 8 * 2 * .pi
                    Circle()
                        .fill(index.isMultiple(of: 2) ? Color.accent : Color.white)
                        .frame(width: 5, height: 5)
                        .offset(x: burst ? cos(angle) * size * 1.1 : 0, y: burst ? sin(angle) * size * 1.1 : 0)
                        .opacity(burst ? 0 : (bounce ? 1 : 0))
                }
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(liked ? .accent : .white)
                    .scaleEffect(bounce ? 1.3 : 1)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(liked ? "Beğenilerden çıkar" : "Beğen")
    }
}

/// Çift dokununca kapağın üstünde büyüyüp kaybolan kalp.
struct HeartPop: View {
    let trigger: Int
    @State private var visible = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 96))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.35), radius: 16)
            .scaleEffect(visible ? 1 : 0.4)
            .opacity(visible ? 0.95 : 0)
            .onChange(of: trigger) { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { visible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeIn(duration: 0.25)) { visible = false }
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Bildirim baloncuğu

struct ToastView: View {
    let toast: AppRouter.Toast

    var body: some View {
        HStack(spacing: 12) {
            if let track = toast.track {
                ArtworkView(url: track.url, size: 38, cornerRadius: 6, fallback: track.artworkFallback)
                    .transition(.scale)
            } else {
                Image(systemName: toast.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.accent)
                    .frame(width: 38, height: 38)
            }
            Text(toast.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.boxSurface2)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .padding(.horizontal, 14)
    }
}
