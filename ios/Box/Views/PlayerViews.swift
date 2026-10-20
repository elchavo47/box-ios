import AVKit
import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    let progress = player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.08))
                        Rectangle()
                            .fill(Color.neon)
                            .frame(width: proxy.size.width * progress)
                            .shadow(color: .neon, radius: 3)
                    }
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    ArtworkView(url: track.url, size: 44, cornerRadius: 6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                        Text(track.displayArtist)
                            .font(.caption)
                            .foregroundColor(.boxSecondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 36, height: 40)
                            .contentShape(Rectangle())
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(
                ZStack {
                    Color.boxCard
                    LinearGradient(colors: [Color.neon.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                player.showFullPlayer = true
            }
        }
    }
}

struct FullPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showQueue = false

    var body: some View {
        ZStack {
            background

            if let track = player.current {
                VStack(spacing: 0) {
                    header(track)

                    Spacer(minLength: 12)

                    artwork(track)

                    Spacer(minLength: 16)

                    titleRow(track)
                        .padding(.horizontal, 28)

                    scrubber
                        .padding(.horizontal, 28)
                        .padding(.top, 18)

                    controls
                        .padding(.top, 14)
                        .padding(.horizontal, 22)

                    bottomBar
                        .padding(.horizontal, 32)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                }
            } else {
                EmptyStateView(icon: "music.note", title: "Çalan bir şey yok", message: "Kitaplıktan bir şarkı seç.")
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: player.current) { newValue in
            if newValue == nil { dismiss() }
        }
    }

    private var background: some View {
        ZStack {
            Color.boxBackground

            if let image = player.currentArtwork {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60)
                    .opacity(0.55)
                    .clipped()
            }

            LinearGradient(
                colors: [Color.black.opacity(0.2), Color.boxBackground.opacity(0.92), Color.boxBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func header(_ track: Track) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("ŞİMDİ ÇALIYOR")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundColor(.boxSecondaryText)
                Text(track.album.isEmpty ? "Box" : track.album)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
            }

            Spacer()

            TrackMenu(track: track)
                .frame(width: 44, height: 44)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.top, 14)
    }

    private func artwork(_ track: Track) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 56, proxy.size.height)
            ArtworkView(url: track.url, size: side, cornerRadius: 18)
                .shadow(color: Color.neon.opacity(player.isPlaying ? 0.35 : 0.1), radius: player.isPlaying ? 30 : 12)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: 380)
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(track.displayArtist)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                library.toggleFavorite(track)
            } label: {
                Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(library.isFavorite(track) ? .neon : .white)
                    .shadow(color: library.isFavorite(track) ? .neon.opacity(0.8) : .clear, radius: 8)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundColor(.white)
    }

    private var scrubber: some View {
        let maxValue = max(player.duration, 1)

        return VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : min(player.currentTime, maxValue) },
                    set: { scrubValue = $0 }
                ),
                in: 0...maxValue,
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = player.currentTime
                        scrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
            )
            .tint(.neon)

            HStack {
                Text(Formatters.time(scrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + Formatters.time(max(player.duration - (scrubbing ? scrubValue : player.currentTime), 0)))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.boxSecondaryText)
        }
    }

    private var controls: some View {
        HStack {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(player.isShuffled ? .neon : .white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 56, height: 56)
            }

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.neon)
                        .frame(width: 78, height: 78)
                        .shadow(color: .neon.opacity(0.7), radius: player.isPlaying ? 18 : 8)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .black))
                        .foregroundColor(.black)
                        .offset(x: player.isPlaying ? 0 : 3)
                }
            }

            Spacer()

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 56, height: 56)
            }

            Spacer()

            Button {
                player.cycleRepeat()
            } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(player.repeatMode == .off ? .white.opacity(0.7) : .neon)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundColor(.white)
    }

    private var bottomBar: some View {
        HStack {
            AirPlayButton()
                .frame(width: 44, height: 44)

            Spacer()

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.8)
        view.activeTintColor = UIColor(red: 0.36, green: 1.0, blue: 0.18, alpha: 1)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Şimdi çalıyor") {
                        TrackRow(track: current, showMenu: false)
                    }
                }

                Section("Sıradakiler") {
                    if player.upNext.isEmpty {
                        Text("Sırada şarkı yok")
                            .foregroundColor(.boxSecondaryText)
                    }

                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                        TrackRow(track: track, showMenu: false)
                            .onTapGesture {
                                if let index = player.currentIndex {
                                    player.jump(to: index + 1 + offset)
                                }
                            }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                }
                .listRowBackground(Color.boxCard)
            }
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .navigationTitle("Sıra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }
}
