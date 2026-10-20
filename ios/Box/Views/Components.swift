import SwiftUI

/// Şarkı kapağı; dosyada kapak yoksa sade bir yer tutucu gösterir.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 6
    var fallback: URL? = nil

    var body: some View {
        ArtworkFill(url: url, maxSide: size * UIScreen.main.scale, fallback: fallback)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Bulunduğu çerçeveyi dolduran kapak (boyut dışarıdan verilir).
struct ArtworkFill: View {
    let url: URL?
    var maxSide: CGFloat = 900
    /// Dosyada kapak yoksa (ör. henüz indirilmemiş şarkı) gösterilecek uzak görsel.
    var fallback: URL? = nil

    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @State private var reload = 0

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            } else if let fallback {
                RemoteThumb(url: fallback)
            } else {
                ArtworkPlaceholder()
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")#\(reload)") {
            guard let url else {
                image = nil
                return
            }
            let loaded = await ArtworkCache.shared.image(for: url, maxSide: maxSide)
            withAnimation(.easeOut(duration: 0.18)) {
                image = loaded
                loadedURL = url
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .boxArtworkReady)) { note in
            if let ready = note.object as? URL, ready == url { reload += 1 }
        }
    }
}

struct ArtworkPlaceholder: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color.boxSurface2, Color.boxSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: max(10, proxy.size.width * 0.32), weight: .medium))
                    .foregroundColor(.white.opacity(0.28))
            }
        }
    }
}

/// Çalan şarkıyı belirten küçük animasyonlu çubuklar.
struct PlayingBars: View {
    var animating: Bool
    var color: Color = .white
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(width: 15, height: 14, alignment: .bottom)
        .onAppear { phase = true }
        .animation(
            animating ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true) : .default,
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
    var showArtwork = true
    var extraMenu: AnyView? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var stream: StreamCache

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 14) {
            if showArtwork {
                ZStack {
                    ArtworkView(url: track.url, size: 52, cornerRadius: 5, fallback: track.artworkFallback)
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                            .frame(width: 52, height: 52)
                        PlayingBars(animating: player.isPlaying)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isCurrent ? .accent : .white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if track.isRemote {
                        Image(systemName: stream.isCached(track.remote?.id ?? "") ? "checkmark.icloud" : "icloud")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    if library.isFavorite(track) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.accent)
                    }
                    Text(track.displayArtist + (track.duration > 0 ? " • " + Formatters.time(track.duration) : ""))
                        .lineLimit(1)
                }
                .font(.system(size: 14))
                .foregroundColor(.boxSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
    var iconColor: Color = .boxSecondaryText

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        if let remote = track.remote {
            remoteMenu(remote)
        } else {
            localMenu
        }
    }

    private var menuIcon: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(iconColor)
            .frame(width: 36, height: 44)
            .contentShape(Rectangle())
    }

    private func remoteMenu(_ remote: SearchResult) -> some View {
        Menu {
            Button { player.playNext(track) } label: { Label("Sıradaki olarak çal", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.addToQueue(track) } label: { Label("Sıraya ekle", systemImage: "text.append") }
            Divider()
            if library.localTrack(for: remote) == nil {
                Button {
                    downloads.download(remote)
                    Haptics.success()
                } label: { Label("Kitaplığa indir", systemImage: "arrow.down.circle") }
            }
            if let url = URL(string: "https://www.youtube.com/watch?v=\(remote.id)") {
                ShareLink(item: url) { Label("Bağlantıyı paylaş", systemImage: "square.and.arrow.up") }
            }
            if let extra {
                Divider()
                extra
            }
        } label: { menuIcon }
    }

    private var localMenu: some View {
        Menu {
            Button {
                player.playNext(track)
            } label: {
                Label("Sıradaki olarak çal", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                player.addToQueue(track)
            } label: {
                Label("Sıraya ekle", systemImage: "text.append")
            }

            Divider()

            Button {
                library.toggleFavorite(track)
                Haptics.tap()
            } label: {
                Label(
                    library.isFavorite(track) ? "Beğenilenlerden çıkar" : "Beğen",
                    systemImage: library.isFavorite(track) ? "heart.slash" : "heart"
                )
            }

            Menu {
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("Yeni liste…", systemImage: "plus")
                }
                if !library.playlists.isEmpty { Divider() }
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        library.add([track], to: playlist.id)
                        Haptics.success()
                    }
                }
            } label: {
                Label("Listeye ekle", systemImage: "text.badge.plus")
            }

            ShareLink(item: track.url) {
                Label("Paylaş", systemImage: "square.and.arrow.up")
            }

            if let extra {
                Divider()
                extra
            }
        } label: { menuIcon }
        .alert("Yeni çalma listesi", isPresented: $showNewPlaylist) {
            TextField("Liste adı", text: $newPlaylistName)
            Button("Oluştur") {
                let playlist = library.createPlaylist(name: newPlaylistName.trimmingCharacters(in: .whitespaces))
                library.add([track], to: playlist.id)
                newPlaylistName = ""
                Haptics.success()
            }
            Button("Vazgeç", role: .cancel) { newPlaylistName = "" }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionTitle = "Tümü"

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.boxSecondaryText)
                }
                Text(title)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundColor(.white)
            }
            Spacer()
            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 16)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.55))
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 19, weight: .bold))
            Text(message)
                .font(.subheadline)
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 220)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Yatay listelerdeki büyük kapak kartı.
struct CoverCard<Cover: View>: View {
    let title: String
    let subtitle: String
    var size: CGFloat = 150
    let cover: Cover

    init(title: String, subtitle: String, size: CGFloat = 150, @ViewBuilder cover: () -> Cover) {
        self.title = title
        self.subtitle = subtitle
        self.size = size
        self.cover = cover()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            cover
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.boxSecondaryText)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
    }
}

/// İlk dört şarkının kapağından mozaik, yoksa ikon.
struct PlaylistCover: View {
    let tracks: [Track]
    let icon: String
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        let covers = Array(tracks.prefix(4))

        ZStack {
            if covers.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(url: covers[0].url, size: size / 2, cornerRadius: 0, fallback: covers[0].artworkFallback)
                        ArtworkView(url: covers[1].url, size: size / 2, cornerRadius: 0, fallback: covers[1].artworkFallback)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(url: covers[2].url, size: size / 2, cornerRadius: 0, fallback: covers[2].artworkFallback)
                        ArtworkView(url: covers[3].url, size: size / 2, cornerRadius: 0, fallback: covers[3].artworkFallback)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(url: first.url, size: size, cornerRadius: 0, fallback: first.artworkFallback)
            } else {
                LinearGradient(colors: [Color.accentDeep.opacity(0.7), Color.boxSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon)
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Üstte yatay kaydırılan filtre çipleri.
struct ChipBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button(title(item)) {
                        withAnimation(.easeOut(duration: 0.18)) { selection = item }
                        Haptics.tap()
                    }
                    .buttonStyle(ChipButtonStyle(selected: selection == item))
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
