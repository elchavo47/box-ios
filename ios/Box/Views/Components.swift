import SwiftUI

/// Şarkı kapağı; dosyada kapak yoksa neon kutulu bir yer tutucu gösterir.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.boxCardHighlight, Color.boxCard],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundColor(.neon.opacity(0.85))
                    .shadow(color: .neon.opacity(0.6), radius: 6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ArtworkCache.shared.image(for: url)
        }
    }
}

/// Çalan şarkıyı belirten küçük animasyonlu çubuklar.
struct PlayingBars: View {
    var animating: Bool
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.neon)
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(width: 14, height: 14, alignment: .bottom)
        .onAppear { phase = true }
        .animation(
            animating ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default,
            value: phase
        )
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard animating else { return 5 }
        let heights: [[CGFloat]] = [[5, 13], [12, 6], [8, 14]]
        return phase ? heights[index][1] : heights[index][0]
    }
}

/// Kitaplık ve listelerde kullanılan şarkı satırı.
struct TrackRow: View {
    let track: Track
    var showMenu = true
    var extraMenu: AnyView? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(url: track.url, size: 50, cornerRadius: 8)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 50, height: 50)
                    PlayingBars(animating: player.isPlaying)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(isCurrent ? .neon : .white)
                    .lineLimit(1)

                Text("\(track.displayArtist) • \(Formatters.time(track.duration))")
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if library.isFavorite(track) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundColor(.neon)
            }

            if showMenu {
                TrackMenu(track: track, extra: extraMenu)
            }
        }
        .contentShape(Rectangle())
    }
}

struct TrackMenu: View {
    let track: Track
    var extra: AnyView? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        Menu {
            Button {
                player.playNext(track)
            } label: {
                Label("Sıradaki olarak çal", systemImage: "text.insert")
            }

            Button {
                player.addToQueue(track)
            } label: {
                Label("Sıraya ekle", systemImage: "text.append")
            }

            Menu {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        library.add([track], to: playlist.id)
                    }
                }
                Divider()
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("Yeni liste…", systemImage: "plus")
                }
            } label: {
                Label("Listeye ekle", systemImage: "music.note.list")
            }

            Button {
                library.toggleFavorite(track)
            } label: {
                Label(
                    library.isFavorite(track) ? "Beğenilenlerden çıkar" : "Beğen",
                    systemImage: library.isFavorite(track) ? "heart.slash" : "heart"
                )
            }

            ShareLink(item: track.url) {
                Label("Paylaş", systemImage: "square.and.arrow.up")
            }

            if let extra {
                Divider()
                extra
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.boxSecondaryText)
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .alert("Yeni çalma listesi", isPresented: $showNewPlaylist) {
            TextField("Liste adı", text: $newPlaylistName)
            Button("Oluştur") {
                let playlist = library.createPlaylist(name: newPlaylistName.trimmingCharacters(in: .whitespaces))
                library.add([track], to: playlist.id)
                newPlaylistName = ""
            }
            Button("Vazgeç", role: .cancel) { newPlaylistName = "" }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var actionTitle = "Tümü"

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.bold))
            Spacer()
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(.horizontal, 16)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundColor(.neon)
                .shadow(color: .neon.opacity(0.7), radius: 12)
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
