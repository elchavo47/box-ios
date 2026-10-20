import AVKit
import MediaPlayer
import SwiftUI

// MARK: - Mini oynatıcı

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var dragX: CGFloat = 0

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(url: track.url, size: 44, cornerRadius: 5, fallback: track.artworkFallback)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(player.isBuffering ? "Hazırlanıyor…" : track.displayArtist)
                            .font(.system(size: 13))
                            .foregroundColor(.boxSecondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: dragX)
                    .opacity(1 - min(abs(dragX) / 160, 0.6))

                    Button {
                        player.togglePlayPause()
                        Haptics.tap()
                    } label: {
                        ZStack {
                            if player.isBuffering {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(player.isPlaying ? "Duraklat" : "Çal")

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sonraki")
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 7)

                MiniProgress(clock: player.clock)
            }
            .background(
                ZStack {
                    Color.boxSurface
                    if let color = player.artworkColor {
                        Color(color).opacity(0.35)
                    }
                }
                .animation(.easeOut(duration: 0.4), value: player.artworkColor)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                player.showFullPlayer = true
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            dragX = value.translation.width * 0.6
                        } else if value.translation.height < -30 {
                            player.showFullPlayer = true
                        }
                    }
                    .onEnded { value in
                        if value.translation.width < -70 { player.next(); Haptics.tap() }
                        else if value.translation.width > 70 { player.previous(); Haptics.tap() }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                    }
            )
        }
    }
}

private struct MiniProgress: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle()
                    .fill(Color.white)
                    .frame(width: proxy.size.width * clock.progress)
            }
        }
        .frame(height: 2)
    }
}

// MARK: - Tam ekran oynatıcı

struct FullPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showSleep = false
    @State private var swipeX: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let artSide = max(160, min(width - 48, proxy.size.height * 0.44))

            ZStack {
                background

                if let track = player.current {
                    VStack(spacing: 0) {
                        header(track)
                            .frame(width: width)

                        Spacer(minLength: 8)

                        Group {
                            if player.videoMode {
                                VideoSurface(player: player.avPlayer)
                                    .frame(width: width, height: width * 9 / 16)
                                    .background(Color.black)
                                    .overlay {
                                        if player.videoLoading || player.isBuffering { ProgressView().tint(.white).scaleEffect(1.3) }
                                    }
                            } else {
                                artwork(track, side: artSide)
                            }
                        }
                        .frame(width: width)
                        .animation(.easeInOut(duration: 0.25), value: player.videoMode)

                        Spacer(minLength: 8)

                        VStack(spacing: 18) {
                            titleRow(track)
                            Scrubber(clock: player.clock) { player.seek(to: $0) }
                            controls
                            bottomBar
                        }
                        .padding(.horizontal, 24)
                        .frame(width: width)
                        .padding(.bottom, max(12, proxy.safeAreaInsets.bottom > 0 ? 4 : 16))
                    }
                    .frame(width: width, height: proxy.size.height)
                } else {
                    EmptyStateView(icon: "music.note", title: "Çalan bir şey yok", message: "Kitaplıktan bir şarkı seç.")
                }
            }
            .frame(width: width, height: proxy.size.height)
        }
        .background(Color.boxBackground.ignoresSafeArea())
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleep) {
            SleepTimerSheet()
                .presentationDetents([.height(470)])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: player.current) { newValue in
            if newValue == nil { dismiss() }
        }
        .alert("Şarkı açılamadı", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("Sonrakine geç") { player.errorMessage = nil; player.next() }
            Button("Tamam", role: .cancel) { player.errorMessage = nil }
        } message: {
            Text(player.errorMessage ?? "")
        }
        .statusBarHidden(false)
    }

    // MARK: Parçalar

    private var background: some View {
        ZStack {
            Color.boxBackground
            LinearGradient(
                colors: [
                    Color(player.artworkColor ?? UIColor(red: 0.12, green: 0.2, blue: 0.17, alpha: 1)),
                    Color(player.artworkColor ?? UIColor(red: 0.12, green: 0.2, blue: 0.17, alpha: 1)).opacity(0.55),
                    Color.boxBackground,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(.easeInOut(duration: 0.6), value: player.artworkColor)
        }
        .ignoresSafeArea()
    }

    private func header(_ track: Track) -> some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Kapat")

            Spacer(minLength: 0)

            Group {
                if player.currentVideoID != nil && auth.isPremium {
                    SongVideoToggle()
                } else {
                    VStack(spacing: 1) {
                        Text("ŞİMDİ ÇALIYOR")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.4)
                            .foregroundColor(.white.opacity(0.6))
                        Text(track.album.isEmpty ? (player.upNext.isEmpty ? "Box" : "\(player.upNext.count) şarkı sırada") : track.album)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            TrackMenu(track: track, iconColor: .white)
                .frame(width: 48, height: 48)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func artwork(_ track: Track, side: CGFloat) -> some View {
        ArtworkView(url: track.url, size: side, cornerRadius: 10, fallback: track.artworkFallback)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            .scaleEffect(player.isPlaying ? 1 : 0.9)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: player.isPlaying)
            .offset(x: swipeX)
            .opacity(1 - min(abs(swipeX) / 400, 0.5))
            .id(track.id)
            .transition(.opacity)
            .contentShape(Rectangle())
            // Yatay kaydırma: sonraki / önceki. Dikey çekişi sistemin kapatma hareketine bırakır.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                        swipeX = value.translation.width
                    }
                    .onEnded { value in
                        if abs(value.translation.width) > abs(value.translation.height) * 1.4 {
                            if value.translation.width < -90 { player.next(); Haptics.tap() }
                            else if value.translation.width > 90 { player.previous(); Haptics.tap() }
                        }
                        if swipeX != 0 { withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { swipeX = 0 } }
                    }
            )
            .onTapGesture(count: 2) {
                if !library.isFavorite(track) { library.toggleFavorite(track); Haptics.success() }
            }
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(text: track.title, font: .system(size: 23, weight: .bold))
                    .frame(height: 30)
                Text(track.displayArtist)
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                library.toggleFavorite(track)
                Haptics.tap()
            } label: {
                Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(library.isFavorite(track) ? .accent : .white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(library.isFavorite(track) ? "Beğenilerden çıkar" : "Beğen")
        }
        .foregroundColor(.white)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            controlButton("shuffle", size: 19, active: player.isShuffled) { player.toggleShuffle() }
            Spacer(minLength: 0)
            controlButton("backward.end.fill", size: 28) { player.previous() }
            Spacer(minLength: 0)

            Button {
                player.togglePlayPause()
                Haptics.tap()
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 74, height: 74)
                    if player.isBuffering {
                        ProgressView().tint(.black).scaleEffect(1.3)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.black)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(PressableStyle(scale: 0.92))
            .accessibilityLabel(player.isPlaying ? "Duraklat" : "Çal")

            Spacer(minLength: 0)
            controlButton("forward.end.fill", size: 28) { player.next() }
            Spacer(minLength: 0)
            controlButton(player.repeatMode.symbol, size: 19, active: player.repeatMode != .off) { player.cycleRepeat() }
        }
        .foregroundColor(.white)
    }

    private func controlButton(_ symbol: String, size: CGFloat, active: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(active == true ? .accent : (active == false ? .white.opacity(0.75) : .white))
                if active != nil {
                    Circle().fill(active == true ? Color.accent : .clear).frame(width: 4, height: 4)
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            AirPlayButton()
                .frame(width: 44, height: 44)

            Spacer(minLength: 0)

            Button {
                showSleep = true
            } label: {
                SleepBadge()
            }

            Spacer(minLength: 0)

            Menu {
                Picker("Hız", selection: Binding(get: { player.playbackRate }, set: { player.setRate($0) })) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                        Text(rateLabel(rate)).tag(rate)
                    }
                }
            } label: {
                Text(rateLabel(player.playbackRate))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(player.playbackRate == 1 ? .white.opacity(0.8) : .accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Çalma hızı")

            Spacer(minLength: 0)

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Sıra")
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == Float(Int(rate)) ? "\(Int(rate))x" : String(format: "%gx", rate)
    }
}

/// Uyku zamanlayıcısı düğmesi: etkinse kalan süreyi gösterir.
private struct SleepBadge: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        if player.sleepTimer.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { _ in content }
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            HStack(spacing: 6) {
                Image(systemName: player.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 18, weight: .semibold))
                if let remaining = player.sleepRemaining {
                    Text(player.sleepTimer == .endOfTrack ? "Şarkı sonu" : Formatters.time(remaining))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundColor(player.sleepTimer.isActive ? .accent : .white.opacity(0.85))
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Uyku zamanlayıcısı")
    }
}

// MARK: - İlerleme çubuğu

struct Scrubber: View {
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0

    private var shown: Double { dragging ? dragValue : clock.currentTime }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let fraction = clock.duration > 0 ? min(max(shown / clock.duration, 0), 1) : 0

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                        .frame(height: dragging ? 7 : 4)
                    Capsule().fill(Color.white)
                        .frame(width: max(0, width * fraction), height: dragging ? 7 : 4)
                    Circle().fill(Color.white)
                        .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                        .offset(x: width * fraction - (dragging ? 9 : 6))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard clock.duration > 0 else { return }
                            if !dragging { Haptics.soft() }
                            dragging = true
                            dragValue = min(max(value.location.x / width, 0), 1) * clock.duration
                        }
                        .onEnded { _ in
                            if dragging { onSeek(dragValue) }
                            dragging = false
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
            .frame(height: 24)

            HStack {
                Text(Formatters.time(shown))
                Spacer()
                Text("-" + Formatters.time(max(clock.duration - shown, 0)))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(dragging ? 0.95 : 0.6))
        }
        .accessibilityElement()
        .accessibilityLabel("Konum")
        .accessibilityValue(Formatters.time(shown))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(clock.currentTime + 10)
            case .decrement: onSeek(clock.currentTime - 10)
            @unknown default: break
            }
        }
    }
}

/// Sığmayan başlığı yavaşça kaydırır.
struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            let overflow = textWidth > proxy.size.width + 1
            let gap: CGFloat = 48

            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    label
                    if overflow { label }
                }
                .fixedSize()
                .offset(x: overflow && animate ? -(textWidth + gap) : 0)
                .animation(
                    overflow && animate
                        ? .linear(duration: Double(textWidth + gap) / 32).delay(2).repeatForever(autoreverses: false)
                        : .default,
                    value: animate
                )
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    if overflow {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    }
                }
            )
            .onAppear { animate = overflow }
            .onChange(of: overflow) { animate = $0 }
        }
        .id(text)
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { inner in
                    Color.clear.onAppear { textWidth = inner.size.width }
                }
            )
    }
}

// MARK: - Ses ve AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.85)
        view.activeTintColor = UIColor(red: 0.243, green: 0.890, blue: 0.604, alpha: 1)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Uyku zamanlayıcısı

struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    private let options = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                if player.sleepTimer.isActive {
                    Section {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack {
                                Image(systemName: "moon.zzz.fill").foregroundColor(.accent)
                                Text(player.sleepTimer == .endOfTrack
                                     ? "Bu şarkı bitince duracak"
                                     : "Müzik \(Formatters.time(player.sleepRemaining ?? 0)) sonra duracak")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                Spacer()
                            }
                        }
                        Button(role: .destructive) {
                            player.cancelSleepTimer()
                            dismiss()
                        } label: {
                            Text("Zamanlayıcıyı kapat")
                        }
                    }
                    .listRowBackground(Color.boxSurface2)
                }

                Section {
                    ForEach(options, id: \.self) { minutes in
                        Button {
                            player.setSleepTimer(minutes: minutes)
                            dismiss()
                        } label: {
                            HStack {
                                Text(minutes < 60 ? "\(minutes) dakika" : (minutes == 60 ? "1 saat" : "1,5 saat"))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                        }
                    }
                    Button {
                        player.setSleepAtEndOfTrack()
                        dismiss()
                    } label: {
                        HStack {
                            Text("Bu şarkının sonunda").foregroundColor(.white)
                            Spacer()
                            if player.sleepTimer == .endOfTrack {
                                Image(systemName: "checkmark").foregroundColor(.accent)
                            }
                        }
                    }
                } footer: {
                    Text("Son 10 saniyede ses yavaşça kısılır. Ekran kilitliyken de çalışır.")
                }
                .listRowBackground(Color.boxSurface2)
            }
            .scrollContentBackground(.hidden)
            .background(Color.boxSurface.ignoresSafeArea())
            .navigationTitle("Uyku zamanlayıcısı")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Sıra

struct QueueView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section {
                        TrackRow(track: current, showMenu: false)
                    } header: {
                        Text("Şimdi çalıyor")
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    if player.upNext.isEmpty {
                        Text("Sırada şarkı yok")
                            .foregroundColor(.boxSecondaryText)
                            .listRowBackground(Color.clear)
                    }

                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                        TrackRow(track: track, showMenu: false)
                            .listRowBackground(Color.clear)
                            .onTapGesture {
                                if let index = player.currentIndex {
                                    player.jump(to: index + 1 + offset)
                                }
                            }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                } header: {
                    HStack {
                        Text("Sıradakiler")
                        Spacer()
                        if !player.upNext.isEmpty {
                            Text("\(player.upNext.count) şarkı • \(Formatters.longDuration(player.upNext.reduce(0) { $0 + $1.duration }))")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.boxSurface.ignoresSafeArea())
            .navigationTitle("Sıra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}


// MARK: - Video

/// YouTube Music'teki gibi Şarkı / Video anahtarı.
private struct SongVideoToggle: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        HStack(spacing: 2) {
            segment(icon: "headphones", label: "Şarkı", active: !player.videoMode) {
                Task { await player.setVideoMode(false) }
            }
            segment(icon: "play.rectangle.fill", label: "Video", active: player.videoMode) {
                Task { await player.setVideoMode(true) }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }

    private func segment(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !active else { return }
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                if label == "Video" && player.videoLoading {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(active ? .black : .white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(active ? Color.white : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Oynatıcının görüntüsünü gösteren katman.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    static func dismantleUIView(_ uiView: LayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}
