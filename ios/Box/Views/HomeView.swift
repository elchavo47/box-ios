import SwiftUI

enum HomeRoute: Hashable {
    case playlist(UUID)
    case favorites
    case downloads
    case recent
    case group(kind: GroupKind, name: String)
    case genre(FeedGenre)
    case smart(SmartList)
    case summary
}

enum SmartList: String, Hashable, CaseIterable {
    case mostPlayed, forgotten, thisMonth

    var title: String {
        switch self {
        case .mostPlayed: return L("En çok dinlediklerin")
        case .forgotten: return L("Uzun süredir dinlemediklerin")
        case .thisMonth: return L("Bu ay eklenenler")
        }
    }

    var icon: String {
        switch self {
        case .mostPlayed: return "flame.fill"
        case .forgotten: return "hourglass"
        case .thisMonth: return "calendar"
        }
    }
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

                    OfflineBanner()
                        .padding(.bottom, 12)

                    ChipBar(items: HomeFilter.allCases, selection: $filter) { L($0.rawValue) }
                        .padding(.top, 4)
                        .padding(.bottom, 18)

                    if library.tracks.isEmpty && !(auth.has(.search) && filter == .all) {
                        if library.hasScanned { emptyLibrary } else { loading }
                    } else {
                        switch filter {
                        case .all: overview
                        case .favorites: trackList(library.favoriteTracks, empty: L("Çalarken kalbe dokunduğun şarkılar burada görünür."))
                        case .recent: trackList(library.recentlyAdded, empty: "")
                        case .downloads: trackList(library.downloadedTracks, empty: auth.has(.search) ? L("Ara sekmesinden indirdiğin şarkılar burada görünür.") : L("Dosyalar sekmesinden müzik ekleyebilirsin."))
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .background(alignment: .top) { HomeGlow() }
            .boxScreenBackground()
            .refreshable {
                await library.refresh()
                if auth.has(.search) { await feed.load(token: auth.token, seeds: FeedStore.seeds(from: library), force: true) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: auth.has(.search)) {
                if auth.has(.search) {
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
            if auth.has(.search) {
                Button {
                    router.tab = .search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(L("Ara"))
            }
            if !auth.isPremium { PremiumHeaderButton() }
            if auth.isLoggedIn { InboxButton() }
            AccountButton()
        }
        .frame(height: 44)
    }

    // MARK: Genel bakış

    private var overview: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !library.tracks.isEmpty { greeting }

            if auth.has(.search) { forYou }

            if !library.recentlyPlayed.isEmpty {
                recentGrid
            }

            if !library.tracks.isEmpty { quickPicks }

            if !library.recentlyAdded.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: L("Son eklenenler"), action: { filter = .recent }, actionTitle: L("Tümü"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(library.recentlyAdded) { track in
                                Button {
                                    player.play(library.recentlyAdded, startAt: library.recentlyAdded.firstIndex(of: track) ?? 0)
                                } label: {
                                    CoverCard(title: track.title, subtitle: track.displayArtist) {
                                        ArtworkFill(url: track.url, maxSide: 450, fallback: track.artworkFallback)
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
                    SectionHeader(title: L("Sanatçılar"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(library.artists.sorted { $0.tracks.count > $1.tracks.count }.prefix(15)) { group in
                                NavigationLink(value: HomeRoute.group(kind: .artist, name: group.name)) {
                                    VStack(spacing: 8) {
                                        ArtworkView(url: group.tracks.first?.url, size: 112, cornerRadius: 56, fallback: group.tracks.first?.artworkFallback)
                                        Text(group.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(L("{0} şarkı", group.tracks.count))
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
    /// Sıra: Sana özel karışık → Ruh haline göre → diğer öneriler.
    @ViewBuilder
    private var forYou: some View {
        if feed.sections.isEmpty && !feed.isLoading, let error = feed.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: L("Sana özel"))
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.icloud").font(.system(size: 22)).foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Öneriler yüklenemedi")).font(.system(size: 15, weight: .semibold))
                        Text(error).font(.system(size: 13)).foregroundColor(.boxSecondaryText).lineLimit(2)
                    }
                    Spacer()
                    Button(L("Tekrar dene")) {
                        Task { await feed.load(token: auth.token, seeds: FeedStore.seeds(from: library), force: true) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.boxSurface))
                .padding(.horizontal, 16)
            }
        }

        if feed.sections.isEmpty && feed.isLoading {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Sana özel"), subtitle: L("Hazırlanıyor"))
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

        ForEach(feed.sections.filter { $0.id == "mix" }) { section in
            feedSection(section)
        }

        if !feed.genres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Ruh haline göre"), subtitle: L("Keşfet"))
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

        ForEach(feed.sections.filter { $0.id != "mix" }) { section in
            feedSection(section)
        }
    }

    private func feedSection(_ section: FeedSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: section.title, subtitle: section.subtitle, action: {
                player.play(library.playable(section.items), startAt: 0)
            }, actionTitle: L("Dinle"))
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

    private static let genreColors: [Color] = [
        Color(red: 0.24, green: 0.89, blue: 0.60), Color(red: 0.98, green: 0.45, blue: 0.40), Color(red: 0.55, green: 0.51, blue: 1.0),
        Color(red: 0.98, green: 0.74, blue: 0.27), Color(red: 0.31, green: 0.76, blue: 0.97), Color(red: 0.95, green: 0.42, blue: 0.72),
    ]

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let text = hour < 6 ? L("İyi geceler") : hour < 12 ? L("Günaydın") : hour < 18 ? L("İyi günler") : L("İyi akşamlar")
        let name = auth.user?.name.split(separator: " ").first.map(String.init)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if auth.user != nil {
                    Button { router.showAccount = true } label: { UserAvatar(user: auth.user, size: 46) }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(L("Profil"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let fullName = auth.user?.name {
                        Text(fullName.uppercased(with: Lang.shared.locale))
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(.boxSecondaryText)
                            .lineLimit(1)
                    }
                    Text(auth.user == nil ? (name.map { "\(text), \($0)" } ?? text) : text)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            HStack(spacing: 10) {
                Button {
                    player.play(library.tracks, startAt: 0, shuffled: true)
                } label: {
                    Label(L("Karışık çal"), systemImage: "shuffle")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    player.play(library.favoriteTracks.isEmpty ? library.tracks : library.favoriteTracks, startAt: 0)
                } label: {
                    Label(library.favoriteTracks.isEmpty ? L("Tümünü çal") : L("Beğenilenler"), systemImage: library.favoriteTracks.isEmpty ? "play.fill" : "heart.fill")
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
            SectionHeader(title: L("Tekrar dinle"), subtitle: L("Son çalınanlar"), action: { path.append(HomeRoute.recent) }, actionTitle: L("Tümü"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: 10) {
                    ForEach(items) { track in
                        Button {
                            player.play(items, startAt: items.firstIndex(of: track) ?? 0)
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                ArtworkFill(url: track.url, maxSide: 450, fallback: track.artworkFallback)
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
            SectionHeader(title: L("Hızlı seçimler"), action: { player.play(picks, startAt: 0) }, actionTitle: L("Tümünü oynat"))
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
            SectionHeader(title: L("Çalma listelerin"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    NavigationLink(value: HomeRoute.favorites) {
                        CoverCard(title: L("Beğenilenler"), subtitle: L("{0} şarkı", library.favoriteTracks.count)) {
                            ZStack {
                                LinearGradient(colors: [Color.accentMid, Color.accentDeep.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "heart.fill").font(.system(size: 44)).foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())

                    if !library.downloadedTracks.isEmpty {
                        NavigationLink(value: HomeRoute.downloads) {
                            CoverCard(title: L("İndirilenler"), subtitle: L("{0} şarkı", library.downloadedTracks.count)) {
                                PlaylistCover(tracks: library.downloadedTracks, icon: "arrow.down", size: 150)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }

                    ForEach(library.playlists) { playlist in
                        let tracks = library.tracks(for: playlist)
                        NavigationLink(value: HomeRoute.playlist(playlist.id)) {
                            CoverCard(title: playlist.name, subtitle: L("{0} şarkı", tracks.count)) {
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
                EmptyStateView(icon: "music.note", title: L("Burada henüz şarkı yok"), message: empty)
            } else {
                HStack(spacing: 10) {
                    Button { player.play(tracks, startAt: 0) } label: { Label(L("Çal"), systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Label(L("Karıştır"), systemImage: "shuffle") }
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
            Text(L("Kitaplık taranıyor…")).font(.subheadline).foregroundColor(.boxSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            BoxMark(size: 76)
                .padding(.top, 56)
            Text(L("Müziğin burada yaşayacak"))
                .font(.system(size: 22, weight: .bold))
            Text(auth.has(.search)
                 ? L("Ara sekmesinden şarkı bul ve indir, ya da Dosyalar'dan kendi müziklerini ekle.")
                 : L("Dosyalar sekmesinden içe aktar, bilgisayardan Finder ile at ya da başka bir uygulamadan \"Box ile aç\" de."))
                .font(.subheadline)
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(auth.has(.search) ? L("Şarkı ara") : L("Dosya ekle")) {
                router.tab = auth.has(.search) ? .search : .files
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
        Button { player.playNext(track) } label: { Label(L("Sıradaki olarak çal"), systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(track) } label: { Label(L("Sıraya ekle"), systemImage: "text.append") }
        Button { library.toggleFavorite(track) } label: {
            Label(library.isFavorite(track) ? L("Beğenilenlerden çıkar") : L("Beğen"), systemImage: library.isFavorite(track) ? "heart.slash" : "heart")
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
            PlaylistDetailView(source: .tracks(title: L("İndirilenler"), icon: "arrow.down", tracks: library.downloadedTracks))
        case .recent:
            PlaylistDetailView(source: .tracks(title: L("Son çalınanlar"), icon: "clock", tracks: library.recentlyPlayed))
        case .genre(let genre):
            GenreView(genre: genre)
        case .summary:
            SummaryView()
        case .smart(let list):
            PlaylistDetailView(source: .tracks(
                title: list.title,
                icon: list.icon,
                tracks: list == .mostPlayed ? library.mostPlayed : (list == .forgotten ? library.forgotten : library.addedThisMonth)
            ))
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


/// Ana sayfanın üstündeki renk geçişi (YouTube Music gibi). Her açılışta 5 renkten biri
/// rastgele seçilir ve uygulama açık kaldıkça değişmez.
private struct HomeGlow: View {
    /// Uygulama her açıldığında bir kez seçilir.
    private static let launchIndex = Int.random(in: 0..<palettes.count)

    /// (üst renk, alttaki ikinci renk)
    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.16, green: 0.30, blue: 0.85), Color(red: 0.05, green: 0.09, blue: 0.32)), // mavi → gece mavisi
        (Color(red: 0.13, green: 0.62, blue: 0.40), Color(red: 0.02, green: 0.16, blue: 0.10)), // Box yeşili → siyah
        (Color(red: 0.45, green: 0.18, blue: 0.82), Color(red: 0.62, green: 0.10, blue: 0.20)), // mor → kırmızı
        (Color(red: 0.06, green: 0.55, blue: 0.62), Color(red: 0.05, green: 0.12, blue: 0.36)), // turkuaz → lacivert
        (Color(red: 0.78, green: 0.20, blue: 0.55), Color(red: 0.25, green: 0.10, blue: 0.55)), // pembe → mor
    ]

    var body: some View {
        layer(Self.palettes[Self.launchIndex])
        .frame(height: 480)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private func layer(_ colors: (Color, Color)) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .top) {
                // Yumuşak, bulanık renk lekeleri (mesh gradient hissi); altta siyaha erir.
                Ellipse().fill(colors.0.opacity(0.75))
                    .frame(width: w * 0.95, height: 300)
                    .offset(x: -w * 0.28, y: -70)
                Ellipse().fill(colors.1.opacity(0.85))
                    .frame(width: w * 0.85, height: 280)
                    .offset(x: w * 0.32, y: 10)
                Circle().fill(colors.0.opacity(0.45))
                    .frame(width: w * 0.6)
                    .offset(x: w * 0.1, y: 150)
            }
            .frame(width: w, height: geo.size.height, alignment: .top)
            .blur(radius: 70)
            .drawingGroup()
            .mask(
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.75), location: 0.45), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .opacity(0.9)
        }
    }
}
