import SwiftUI

/// Sanatçı ve albüm sayfaları (YouTube Music). Her yerden açılır, kendi içinde gezilir.
enum MusicPage: Hashable, Identifiable {
    case artist(id: String?, name: String)
    case album(id: String?, name: String, artist: String)

    var id: String {
        switch self {
        case .artist(let id, let name): return "artist:" + (id ?? name)
        case .album(let id, let name, let artist): return "album:" + (id ?? name + "|" + artist)
        }
    }

    /// Bir şarkının sanatçı sayfası.
    static func artistPage(for track: Track) -> MusicPage {
        .artist(id: track.remote?.artistId, name: track.displayArtist.replacingOccurrences(of: " - Topic", with: ""))
    }

    /// Bir şarkının albüm sayfası (albüm bilinmiyorsa nil).
    static func albumPage(for track: Track) -> MusicPage? {
        if let remote = track.remote, let id = remote.albumId {
            return .album(id: id, name: remote.album ?? "", artist: track.displayArtist)
        }
        let name = track.album.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return .album(id: nil, name: name, artist: track.displayArtist)
    }
}

/// Sanatçı / albüm sayfalarının kabı: kendi gezinme yığını ve mini oynatıcısı.
struct MusicBrowser: View {
    let root: MusicPage
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        NavigationStack {
            MusicPageView(page: root)
                .navigationDestination(for: MusicPage.self) { MusicPageView(page: $0) }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .accessibilityLabel("Kapat")
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SheetMiniPlayer() }
        // Bu sayfa açıkken mini oynatıcıya basılırsa tam ekran oynatıcı buradan açılır.
        .sheet(isPresented: $player.showFullPlayer) { FullPlayerView() }
        .presentationDragIndicator(.visible)
    }
}

private struct MusicPageView: View {
    let page: MusicPage

    var body: some View {
        switch page {
        case .artist(let id, let name): ArtistView(artistID: id, name: name)
        case .album(let id, let name, let artist): AlbumView(albumID: id, name: name, artist: artist)
        }
    }
}

/// Sayfa içinden de çalan şarkı görünsün.
private struct SheetMiniPlayer: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        if player.current != nil {
            MiniPlayerBar()
                .background(Color(red: 0.035, green: 0.037, blue: 0.045).ignoresSafeArea(edges: .bottom))
        }
    }
}

// MARK: - Sanatçı

struct ArtistView: View {
    let artistID: String?
    let name: String

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    @State private var page: ArtistPage?
    @State private var error: String?
    @State private var showAllSongs = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            if let page {
                content(page)
            } else if let error {
                EmptyStateView(icon: "music.mic", title: "Açılamadı", message: error, actionTitle: "Tekrar dene") { Task { await load() } }
                    .padding(.top, 80)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 160)
            }
        }
        .background(Color.boxBackground.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
    }

    private func content(_ page: ArtistPage) -> some View {
        let songs = page.songs
        let tracks = library.playable(songs)
        let toggleAll: (() -> Void)? = songs.count > 5 ? { withAnimation { showAllSongs.toggle() } } : nil
        return VStack(alignment: .leading, spacing: 26) {
            // Kapak: sanatçı fotoğrafı, altta isim.
            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(url: page.artist.thumbnailURL, maxSide: 1000) { ArtistPlaceholder() }
                    .frame(maxWidth: .infinity)
                    .frame(height: 340)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.35), Color.boxBackground], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.artist.name)
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    if let listeners = page.artist.listeners, !listeners.isEmpty {
                        Text(listeners)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

            HStack(spacing: 10) {
                Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Label("Karıştır", systemImage: "shuffle") }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    if let first = tracks.first { player.startRadio(from: first) }
                } label: { Label("Radyo", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
            }
            .disabled(tracks.isEmpty)
            .padding(.horizontal, 16)

            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Popüler şarkılar", action: toggleAll, actionTitle: showAllSongs ? "Daha az" : "Tümü")
                    ForEach(Array(songs.prefix(showAllSongs ? songs.count : 5).enumerated()), id: \.element.id) { index, result in
                        OnlineResultRow(result: result) { player.play(tracks, startAt: index) }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                }
            }

            if !page.albums.isEmpty { albumRow("Albümler", page.albums) }
            if !page.singles.isEmpty { albumRow("Single ve EP'ler", page.singles) }

            if !page.related.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Benzer sanatçılar")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(page.related) { artist in
                                NavigationLink(value: MusicPage.artist(id: artist.id, name: artist.name)) {
                                    ArtistCircle(artist: artist, size: 120)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            if let about = page.artist.description, !about.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hakkında").font(.system(size: 23, weight: .bold))
                    Text(about)
                        .font(.system(size: 15))
                        .foregroundColor(.boxSecondaryText)
                        .lineLimit(showAbout ? nil : 4)
                        .onTapGesture { withAnimation { showAbout.toggle() } }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 30)
    }

    private func albumRow(_ title: String, _ albums: [AlbumCard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: MusicPage.album(id: album.id, name: album.title, artist: album.artist ?? name)) {
                            CoverCard(title: album.title, subtitle: [album.type, album.year].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " • ")) {
                                RemoteThumb(url: album.thumbnailURL, maxSide: 450)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        error = nil
        guard let token = auth.token else { error = "Giriş yapman gerekiyor."; return }
        var query: [String: String] = [:]
        if let artistID { query["id"] = artistID } else { query["name"] = name }
        do {
            page = try await APIClient.shared.send("artist", query: query, token: token)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Sanatçı açılamadı."
        }
    }
}

private struct ArtistPlaceholder: View {
    var body: some View {
        LinearGradient(colors: [Color.accentDeep.opacity(0.6), Color.boxSurface], startPoint: .top, endPoint: .bottom)
            .overlay(Image(systemName: "music.mic").font(.system(size: 60)).foregroundColor(.white.opacity(0.3)))
    }
}

struct ArtistCircle: View {
    let artist: ArtistCard
    var size: CGFloat = 112

    var body: some View {
        VStack(spacing: 8) {
            CachedRemoteImage(url: artist.thumbnailURL, maxSide: size * 3) { ArtworkPlaceholder() }
                .frame(width: size, height: size)
                .clipShape(Circle())
            Text(artist.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(width: size)
    }
}

/// Arama sonuçlarının en üstünde: aranan sanatçı.
struct TopArtistRow: View {
    let artist: ArtistCard
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button {
            router.openMusic(.artist(id: artist.id, name: artist.name))
        } label: {
            HStack(spacing: 14) {
                CachedRemoteImage(url: artist.thumbnailURL, maxSide: 200) { ArtworkPlaceholder() }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Text("Sanatçı • sayfasını aç")
                        .font(.system(size: 13))
                        .foregroundColor(.boxSecondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.boxSecondaryText)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.boxSurface))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

// MARK: - Albüm

struct AlbumView: View {
    let albumID: String?
    let name: String
    let artist: String

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var page: AlbumPage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let page {
                content(page)
            } else if let error {
                EmptyStateView(icon: "square.stack", title: "Açılamadı", message: error, actionTitle: "Tekrar dene") { Task { await load() } }
                    .padding(.top, 80)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 160)
            }
        }
        .background(Color.boxBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
    }

    private func content(_ page: AlbumPage) -> some View {
        let tracks = library.playable(page.tracks)
        let missing = page.tracks.filter { library.localTrack(for: $0) == nil }
        let total = page.tracks.reduce(0) { $0 + $1.duration }
        let meta = [page.album.type, page.album.year, "\(page.tracks.count) şarkı", total > 0 ? Formatters.longDuration(Double(total)) : nil]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " • ")

        return VStack(spacing: 18) {
            RemoteThumb(url: page.album.thumbnailURL, maxSide: 900)
                .frame(width: 230, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(page.album.title)
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                if let albumArtist = page.album.artist, !albumArtist.isEmpty {
                    NavigationLink(value: MusicPage.artist(id: page.album.artistId, name: albumArtist)) {
                        Text(albumArtist)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accent)
                    }
                }
                Text(meta)
                    .font(.system(size: 13))
                    .foregroundColor(.boxSecondaryText)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Button { player.play(tracks, startAt: 0) } label: { Label("Dinle", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Label("Karıştır", systemImage: "shuffle") }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
                Button {
                    downloads.download(all: missing)
                    Haptics.success()
                } label: {
                    DownloadFillIcon(progress: missing.isEmpty ? 1 : nil, size: 26, done: missing.isEmpty)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .disabled(missing.isEmpty)
                .accessibilityLabel(missing.isEmpty ? "Hepsi indirildi" : "Albümü indir")
            }
            .disabled(tracks.isEmpty)
            .padding(.horizontal, 16)

            LazyVStack(spacing: 0) {
                ForEach(Array(page.tracks.enumerated()), id: \.element.id) { index, result in
                    AlbumTrackRow(number: index + 1, result: result, albumArtist: page.album.artist ?? artist) {
                        player.play(tracks, startAt: tracks.firstIndex { $0.remote?.id == result.id || library.localTrack(for: result)?.id == $0.id } ?? index)
                    }
                }
            }
        }
        .padding(.bottom, 30)
    }

    private func load() async {
        error = nil
        guard let token = auth.token else { error = "Giriş yapman gerekiyor."; return }
        var query: [String: String] = [:]
        if let albumID { query["id"] = albumID } else { query["name"] = name; query["artist"] = artist }
        do {
            page = try await APIClient.shared.send("album", query: query, token: token)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Albüm açılamadı."
        }
    }
}

private struct AlbumTrackRow: View {
    let number: Int
    let result: SearchResult
    let albumArtist: String
    let onPlay: () -> Void

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    private var isCurrent: Bool {
        player.current?.remote?.id == result.id || (player.current.map { library.localTrack(for: result)?.id == $0.id } ?? false)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    ZStack {
                        if isCurrent {
                            PlayingBars(animating: player.isPlaying, color: .accent)
                        } else {
                            Text("\(number)")
                                .font(.system(size: 15, weight: .medium).monospacedDigit())
                                .foregroundColor(.boxSecondaryText)
                        }
                    }
                    .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(isCurrent ? .accent : .white)
                            .lineLimit(1)
                        if result.channel != albumArtist && !result.channel.isEmpty {
                            Text(result.channel)
                                .font(.system(size: 13))
                                .foregroundColor(.boxSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if result.duration > 0 {
                        Text(Formatters.time(Double(result.duration)))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundColor(.boxSecondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))

            Button {
                if library.localTrack(for: result) == nil { downloads.download(result); Haptics.tap() }
            } label: {
                DownloadIndicator(state: downloads.state(for: result.id), downloaded: library.localTrack(for: result) != nil)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Bildirim kutusu

@MainActor
final class InboxStore: ObservableObject {
    static let shared = InboxStore()

    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var loading = false
    @Published private(set) var lastSeenID = 0

    private var userID: Int?
    private var key: String { "box.inbox.seen.\(userID ?? 0)" }

    var unread: Int { items.filter { $0.id > lastSeenID }.count }

    func load(token: String?, userID: Int?) async {
        guard let token, let userID else { items = []; return }
        if self.userID != userID {
            self.userID = userID
            lastSeenID = UserDefaults.standard.integer(forKey: key)
        }
        loading = true
        defer { loading = false }
        if let response: InboxResponse = try? await APIClient.shared.send("me/notifications", token: token) {
            items = response.items
        }
    }

    func markAllRead() {
        guard let newest = items.first?.id, newest > lastSeenID else { return }
        lastSeenID = newest
        UserDefaults.standard.set(newest, forKey: key)
    }

    func reset() {
        items = []
        userID = nil
        lastSeenID = 0
    }
}

/// Ana sayfanın sağ üstündeki zil: okunmamış varsa yeşil nokta.
struct InboxButton: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var inbox = InboxStore.shared

    var body: some View {
        Button { router.showInbox = true } label: {
            Image(systemName: inbox.unread > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.accent)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel(inbox.unread > 0 ? "Bildirimler, \(inbox.unread) okunmamış" : "Bildirimler")
    }
}

struct InboxView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var inbox = InboxStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var seenBefore = 0

    var body: some View {
        NavigationStack {
            List {
                if inbox.items.isEmpty {
                    EmptyStateView(icon: "bell", title: inbox.loading ? "Yükleniyor…" : "Bildirim yok", message: "Box'tan gelen duyurular ve hesabınla ilgili bildirimler burada durur.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(inbox.items) { item in
                    Button {
                        if let open = item.open {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { PushManager.shared.handle(userInfo: ["box": ["open": open]]) }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(item.id > seenBefore ? Color.accent : Color.clear)
                                .frame(width: 8, height: 8)
                                .padding(.top, 7)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                    Spacer(minLength: 8)
                                    if let date = item.date {
                                        Text(date, style: .relative)
                                            .font(.system(size: 12))
                                            .foregroundColor(.boxTertiaryText)
                                    }
                                }
                                Text(item.body)
                                    .font(.system(size: 14))
                                    .foregroundColor(.boxSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                        .opacity(item.id > seenBefore ? 1 : 0.72)
                    }
                    .listRowBackground(Color.boxSurface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.boxBackground.ignoresSafeArea())
            .navigationTitle("Bildirimler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { dismiss() }.fontWeight(.semibold)
                }
            }
            .refreshable { await inbox.load(token: auth.token, userID: auth.user?.id) }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            seenBefore = inbox.lastSeenID
            inbox.markAllRead()
        }
        .task {
            await inbox.load(token: auth.token, userID: auth.user?.id)
            inbox.markAllRead()
        }
    }
}
