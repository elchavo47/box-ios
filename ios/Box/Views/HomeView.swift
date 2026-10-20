import SwiftUI

enum HomeRoute: Hashable {
    case playlist(UUID)
    case favorites
    case downloads
    case recent
    case group(kind: GroupKind, name: String)
    case genre(FeedGenre)
}

enum GroupKind: String, Hashable {
    case artist, album
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var stream: StreamCache

    @State private var path = NavigationPath()
    @State private var filter: HomeFilter = .all

    enum HomeFilter: String, CaseIterable, Hashable {
        case all = "Tümü"
        case favorites = "Beğenilenler"
        case recent = "Son eklenenler"
        case downloads = "İndirilenler"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 14)

                    ChipBar(items: HomeFilter.allCases, selection: $filter) { $0.rawValue }
                        .padding(.top, 4)
                        .padding(.bottom, 18)

                    if library.tracks.isEmpty && !(auth.isPremium && filter == .all) {
                        if library.hasScanned { emptyLibrary } else { loading }
                    } else {
                        switch filter {
                        case .all: overview
                        case .favorites: trackList(library.favoriteTracks, empty: "Çalarken kalbe dokunduğun şarkılar burada görünür.")
                        case .recent: trackList(library.recentlyAdded, empty: "")
                        case .downloads: trackList(library.downloadedTracks, empty: auth.isPremium ? "Ara sekmesinden indirdiğin şarkılar burada görünür." : "Dosyalar sekmesinden müzik ekleyebilirsin.")
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .boxScreenBackground()
            .refreshable {
                await library.refresh()
                if auth.isPremium { await feed.load(token: auth.token, seeds: FeedStore.seeds(from: library), force: true) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: auth.isPremium) {
                if auth.isPremium {
                    await feed.load(token: auth.token, seeds: FeedStore.seeds(from: library))
                    stream.warm(feed.sections.flatMap { $0.items.prefix(2) }, limit: 6)
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                HomeRouteView(route: route)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BoxWordmark(markSize: 26)
            Spacer()
            if auth.isPremium {
                Button {
                    router.tab = .search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Ara")
            }
            AccountButton()
        }
        .frame(height: 44)
    }

    // MARK: Genel bakış

    private var overview: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !library.tracks.isEmpty { greeting }

            if auth.isPremium { forYou }

            if !library.recentlyPlayed.isEmpty {
                recentGrid
            }

            if !library.tracks.isEmpty { quickPicks }

            if !library.recentlyAdded.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Son eklenenler", action: { filter = .recent }, actionTitle: "Tümü")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(library.recentlyAdded) { track in
                                Button {
                                    player.play(library.recentlyAdded, startAt: library.recentlyAdded.firstIndex(of: track) ?? 0)
                                } label: {
                                    CoverCard(title: track.title, subtitle: track.displayArtist) {
                                        ArtworkFill(url: track.url, maxSide: 450)
                                    }
                                }
                                .buttonStyle(PressableStyle())
                                .contextMenu { TrackContextItems(track: track) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            if !library.tracks.isEmpty || !library.playlists.isEmpty { playlistsRow }

            if library.artists.count > 1 {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Sanatçılar")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(library.artists.sorted { $0.tracks.count > $1.tracks.count }.prefix(15)) { group in
                                NavigationLink(value: HomeRoute.group(kind: .artist, name: group.name)) {
                                    VStack(spacing: 8) {
                                        ArtworkView(url: group.tracks.first?.url, size: 112, cornerRadius: 56)
                                        Text(group.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text("\(group.tracks.count) şarkı")
                                            .font(.system(size: 12))
                                            .foregroundColor(.boxSecondaryText)
                                    }
                                    .frame(width: 112)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    /// Premium: dinleme geçmişine göre öneriler ve türler.
    @ViewBuilder
    private var forYou: some View {
        if !feed.genres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Ruh haline göre", subtitle: "Keşfet")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(44), spacing: 10), GridItem(.fixed(44), spacing: 10)], spacing: 10) {
                        ForEach(Array(feed.genres.enumerated()), id: \.element.id) { index, genre in
                            NavigationLink(value: HomeRoute.genre(genre)) {
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(Self.genreColors[index % Self.genreColors.count])
                                        .frame(width: 5)
                                    Text(genre.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .padding(.horizontal, 14)
                                    Spacer(minLength: 0)
                                }
                                .frame(width: 168, height: 44)
                                .background(Color.boxSurface2)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 98)
            }
        }

        if feed.sections.isEmpty && feed.isLoading {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Sana özel", subtitle: "Hazırlanıyor")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 150, height: 150)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }

        ForEach(feed.sections) { section in
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: section.title, subtitle: section.subtitle, action: {
                    player.play(library.playable(section.items), startAt: 0)
                }, actionTitle: "Dinle")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            RemoteCard(result: item) {
                                player.play(library.playable(section.items), startAt: index)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private static let genreColors: [Color] = [
        Color(red: 0.24, green: 0.89, blue: 0.60), Color(red: 0.98, green: 0.45, blue: 0.40), Color(red: 0.55, green: 0.51, blue: 1.0),
        Color(red: 0.98, green: 0.74, blue: 0.27), Color(red: 0.31, green: 0.76, blue: 0.97), Color(red: 0.95, green: 0.42, blue: 0.72),
    ]

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let text = hour < 6 ? "İyi geceler" : hour < 12 ? "Günaydın" : hour < 18 ? "İyi günler" : "İyi akşamlar"
        let name = auth.user?.name.split(separator: " ").first.map(String.init)

        return VStack(alignment: .leading, spacing: 14) {
            Text(name.map { "\(text), \($0)" } ?? text)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 10) {
                Button {
                    player.play(library.tracks, startAt: 0, shuffled: true)
                } label: {
                    Label("Karışık çal", systemImage: "shuffle")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    player.play(library.favoriteTracks.isEmpty ? library.tracks : library.favoriteTracks, startAt: 0)
                } label: {
                    Label(library.favoriteTracks.isEmpty ? "Tümünü çal" : "Beğenilenler", systemImage: library.favoriteTracks.isEmpty ? "play.fill" : "heart.fill")
                }
                .buttonStyle(PrimaryButtonStyle(filled: false))
            }
        }
        .padding(.horizontal, 16)
    }

    /// YouTube Music'teki gibi iki satırlı kapak ızgarası.
    private var recentGrid: some View {
        let items = Array(library.recentlyPlayed.prefix(12))
        let rows = [GridItem(.fixed(150), spacing: 10), GridItem(.fixed(150), spacing: 10)]

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Tekrar dinle", subtitle: "Son çalınanlar", action: { path.append(HomeRoute.recent) }, actionTitle: "Tümü")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: 10) {
                    ForEach(items) { track in
                        Button {
                            player.play(items, startAt: items.firstIndex(of: track) ?? 0)
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                ArtworkFill(url: track.url, maxSide: 450)
                                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                                Text(track.title)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(10)
                                if player.current?.id == track.id {
                                    PlayingBars(animating: player.isPlaying)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                }
                            }
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu { TrackContextItems(track: track) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 310)
        }
    }

    private var quickPicks: some View {
        let picks = library.quickPicks
        let columns = stride(from: 0, to: picks.count, by: 4).map { Array(picks[$0..<min($0 + 4, picks.count)]) }

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Hızlı seçimler", action: { player.play(picks, startAt: 0) }, actionTitle: "Tümünü oynat")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(columns.indices, id: \.self) { column in
                        VStack(spacing: 4) {
                            ForEach(columns[column]) { track in
                                TrackRow(track: track)
                                    .frame(height: 60)
                                    .onTapGesture { player.play(picks, startAt: picks.firstIndex(of: track) ?? 0) }
                            }
                        }
                        .frame(width: UIScreen.main.bounds.width - 52)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var playlistsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Çalma listelerin")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    NavigationLink(value: HomeRoute.favorites) {
                        CoverCard(title: "Beğenilenler", subtitle: "\(library.favoriteTracks.count) şarkı") {
                            ZStack {
                                LinearGradient(colors: [Color.accentMid, Color.accentDeep.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "heart.fill").font(.system(size: 44)).foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())

                    if !library.downloadedTracks.isEmpty {
                        NavigationLink(value: HomeRoute.downloads) {
                            CoverCard(title: "İndirilenler", subtitle: "\(library.downloadedTracks.count) şarkı") {
                                PlaylistCover(tracks: library.downloadedTracks, icon: "arrow.down", size: 150)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }

                    ForEach(library.playlists) { playlist in
                        let tracks = library.tracks(for: playlist)
                        NavigationLink(value: HomeRoute.playlist(playlist.id)) {
                            CoverCard(title: playlist.name, subtitle: "\(tracks.count) şarkı") {
                                PlaylistArtwork(playlist: playlist, tracks: tracks, size: 150)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Liste görünümü

    private func trackList(_ tracks: [Track], empty: String) -> some View {
        LazyVStack(spacing: 0) {
            if tracks.isEmpty {
                EmptyStateView(icon: "music.note", title: "Burada henüz şarkı yok", message: empty)
            } else {
                HStack(spacing: 10) {
                    Button { player.play(tracks, startAt: 0) } label: { Label("Çal", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Label("Karıştır", systemImage: "shuffle") }
                        .buttonStyle(PrimaryButtonStyle(filled: false))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            ForEach(tracks) { track in
                TrackRow(track: track)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .onTapGesture { player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0) }
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text("Kitaplık taranıyor…").font(.subheadline).foregroundColor(.boxSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            BoxMark(size: 76)
                .padding(.top, 56)
            Text("Müziğin burada yaşayacak")
                .font(.system(size: 22, weight: .bold))
            Text(auth.isPremium
                 ? "Ara sekmesinden şarkı bul ve indir, ya da Dosyalar'dan kendi müziklerini ekle."
                 : "Dosyalar sekmesinden içe aktar, bilgisayardan Finder ile at ya da başka bir uygulamadan \"Box ile aç\" de.")
                .font(.subheadline)
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(auth.isPremium ? "Şarkı ara" : "Dosya ekle") {
                router.tab = auth.isPremium ? .search : .files
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(width: 200)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Uzun basınca açılan menü (kartlar için).
struct TrackContextItems: View {
    let track: Track
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Button { player.playNext(track) } label: { Label("Sıradaki olarak çal", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(track) } label: { Label("Sıraya ekle", systemImage: "text.append") }
        Button { library.toggleFavorite(track) } label: {
            Label(library.isFavorite(track) ? "Beğenilenlerden çıkar" : "Beğen", systemImage: library.isFavorite(track) ? "heart.slash" : "heart")
        }
    }
}

/// Ana sayfa ve kitaplıktaki ortak sayfalar.
struct HomeRouteView: View {
    let route: HomeRoute
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        switch route {
        case .playlist(let id):
            PlaylistDetailView(source: .playlist(id))
        case .favorites:
            PlaylistDetailView(source: .favorites)
        case .downloads:
            PlaylistDetailView(source: .tracks(title: "İndirilenler", icon: "arrow.down", tracks: library.downloadedTracks))
        case .recent:
            PlaylistDetailView(source: .tracks(title: "Son çalınanlar", icon: "clock", tracks: library.recentlyPlayed))
        case .genre(let genre):
            GenreView(genre: genre)
        case .group(let kind, let name):
            let groups = kind == .artist ? library.artists : library.albums
            PlaylistDetailView(source: .tracks(
                title: name,
                icon: kind == .artist ? "music.mic" : "square.stack",
                tracks: groups.first { $0.name == name }?.tracks ?? []
            ))
        }
    }
}
