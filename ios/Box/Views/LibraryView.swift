import SwiftUI
import UniformTypeIdentifiers

enum TrackSort: String, CaseIterable, Identifiable {
    case title = "Ada göre"
    case artist = "Sanatçıya göre"
    case added = "Eklenme tarihine göre"
    case plays = "En çok dinlenen"

    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore

    @State private var path = NavigationPath()
    @State private var showImport = false
    @State private var showListFile = false
    @State private var importMessage: String?
    @State private var section: LibSection = .playlists
    @State private var searchText = ""
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @AppStorage("box.sort") private var sort: TrackSort = .title

    enum LibSection: String, CaseIterable, Hashable {
        case playlists = "Listeler"
        case songs = "Şarkılar"
        case artists = "Sanatçılar"
        case albums = "Albümler"
    }

    private var sortedTracks: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let base = query.isEmpty ? library.tracks : library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .title:
            return base
        case .artist:
            return base.sorted { $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist) == .orderedAscending }
        case .added:
            return base.sorted { $0.addedAt > $1.addedAt }
        case .plays:
            return base.sorted { (library.playCounts[$0.relativePath] ?? 0) > (library.playCounts[$1.relativePath] ?? 0) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ChipBar(items: LibSection.allCases, selection: $section) { $0.rawValue }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                switch section {
                case .playlists: playlists
                case .songs: songs
                case .artists: groups(library.artists, kind: .artist)
                case .albums: groups(library.albums, kind: .album)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .navigationTitle("Kitaplık")
            .searchable(text: $searchText, prompt: "Kitaplığında ara")
            .onChange(of: searchText) { text in
                if !text.isEmpty && section == .playlists { section = .songs }
            }
            .refreshable { await library.refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if library.isScanning {
                        ProgressView().tint(.white)
                    }
                    if section == .songs {
                        Menu {
                            Picker("Sırala", selection: $sort) {
                                ForEach(TrackSort.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                    if section == .playlists {
                        Menu {
                            Button { showNewPlaylist = true } label: { Label("Yeni çalma listesi", systemImage: "plus") }
                            if auth.isPremium {
                                Button { showImport = true } label: { Label("YouTube listesini içe aktar", systemImage: "square.and.arrow.down.on.square") }
                            }
                            Button { showListFile = true } label: { Label("Liste dosyası aç (.boxlist)", systemImage: "doc.badge.plus") }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Liste ekle")
                    }
                    AccountButton()
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                HomeRouteView(route: route)
            }
            .sheet(isPresented: $showImport) {
                PlaylistImportView()
            }
            .fileImporter(isPresented: $showListFile, allowedContentTypes: [.boxPlaylist, .json]) { result in
                guard case .success(let url) = result else { return }
                if let shared = BackupService.read(SharedPlaylist.self, from: url), shared.kind == "box.playlist" {
                    let playlist = library.importShared(shared)
                    path.append(HomeRoute.playlist(playlist.id))
                } else {
                    importMessage = "Bu dosya bir Box listesi değil."
                }
            }
            .alert("İçe aktarma", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("Tamam", role: .cancel) {}
            } message: { Text(importMessage ?? "") }
            .alert("Yeni çalma listesi", isPresented: $showNewPlaylist) {
                TextField("Liste adı", text: $newPlaylistName)
                Button("Oluştur") {
                    let playlist = library.createPlaylist(name: newPlaylistName.trimmingCharacters(in: .whitespaces))
                    newPlaylistName = ""
                    path.append(HomeRoute.playlist(playlist.id))
                }
                Button("Vazgeç", role: .cancel) { newPlaylistName = "" }
            }
        }
    }

    // MARK: Bölümler

    @ViewBuilder
    private var playlists: some View {
        Button {
            showNewPlaylist = true
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundColor(.white))
                Text("Yeni çalma listesi")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        playlistRow(title: "Beğenilenler", subtitle: "Otomatik liste • \(library.favoriteTracks.count) şarkı", route: .favorites) {
            ZStack {
                LinearGradient(colors: [Color.accentMid, Color.accentDeep.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "heart.fill").foregroundColor(.white)
            }
        }

        if !library.downloadedTracks.isEmpty {
            playlistRow(title: "İndirilenler", subtitle: "Otomatik liste • \(library.downloadedTracks.count) şarkı", route: .downloads) {
                PlaylistCover(tracks: library.downloadedTracks, icon: "arrow.down", size: 56, cornerRadius: 0)
            }
        }

        playlistRow(title: "Box Özeti", subtitle: "Dinleme istatistiklerin", route: .summary) {
            ZStack {
                LinearGradient(colors: [Color.accent, Color(red: 0.62, green: 0.95, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "chart.bar.fill").foregroundColor(.black)
            }
        }

        ForEach(SmartList.allCases, id: \.self) { list in
            let count = list == .mostPlayed ? library.mostPlayed.count : (list == .forgotten ? library.forgotten.count : library.addedThisMonth.count)
            if count > 0 {
                playlistRow(title: list.title, subtitle: "Akıllı liste • \(count) şarkı", route: .smart(list)) {
                    ZStack {
                        Color.boxSurface2
                        Image(systemName: list.icon).foregroundColor(.accent)
                    }
                }
            }
        }

        if !library.recentlyPlayed.isEmpty {
            playlistRow(title: "Son çalınanlar", subtitle: "Otomatik liste • \(library.recentlyPlayed.count) şarkı", route: .recent) {
                PlaylistCover(tracks: library.recentlyPlayed, icon: "clock", size: 56, cornerRadius: 0)
            }
        }

        ForEach(library.playlists) { playlist in
            let tracks = library.tracks(for: playlist)
            playlistRow(title: playlist.name, subtitle: (playlist.sourceID != nil ? "YouTube listesi" : "Liste") + " • \(tracks.count) şarkı", route: .playlist(playlist.id)) {
                PlaylistArtwork(playlist: playlist, tracks: tracks, size: 56, cornerRadius: 0)
            }
            .swipeActions {
                Button(role: .destructive) {
                    library.deletePlaylist(playlist.id)
                } label: {
                    Label("Sil", systemImage: "trash")
                }
            }
        }
    }

    private func playlistRow<Cover: View>(title: String, subtitle: String, route: HomeRoute, @ViewBuilder cover: () -> Cover) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                cover()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.boxSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var songs: some View {
        let tracks = sortedTracks

        if tracks.isEmpty {
            EmptyStateView(
                icon: searchText.isEmpty ? "music.note" : "magnifyingglass",
                title: searchText.isEmpty ? "Henüz şarkı yok" : "Sonuç yok",
                message: searchText.isEmpty ? "Dosyalar sekmesinden müzik ekle." : "\"\(searchText)\" ile eşleşen şarkı bulunamadı."
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            HStack(spacing: 10) {
                Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Label("Karıştır", systemImage: "shuffle") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { player.play(tracks, startAt: 0) } label: { Label("Çal", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Text("\(tracks.count) şarkı • \(Formatters.bytes(library.totalSize))")
                .font(.footnote)
                .foregroundColor(.boxSecondaryText)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(tracks) { track in
                TrackRow(track: track)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 8))
                    .onTapGesture {
                        player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                    }
                    .swipeActions(edge: .leading) {
                        Button { player.playNext(track) } label: { Label("Sıradaki", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(.accentDeep)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { player.addToQueue(track) } label: { Label("Sıraya ekle", systemImage: "text.append") }
                            .tint(.gray)
                    }
            }
        }
    }

    @ViewBuilder
    private func groups(_ groups: [LibraryStore.TrackGroup], kind: GroupKind) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? groups : groups.filter { $0.name.localizedCaseInsensitiveContains(query) }

        if shown.isEmpty {
            EmptyStateView(
                icon: kind == .artist ? "music.mic" : "square.stack",
                title: kind == .artist ? "Sanatçı yok" : "Albüm yok",
                message: kind == .album ? "Dosyalarında albüm bilgisi olan şarkılar burada gruplanır." : "Şarkı ekledikçe sanatçılar burada görünür."
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        ForEach(shown) { group in
            NavigationLink(value: HomeRoute.group(kind: kind, name: group.name)) {
                HStack(spacing: 14) {
                    ArtworkView(url: group.tracks.first?.url, size: 56, cornerRadius: kind == .artist ? 28 : 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("\(group.tracks.count) şarkı • \(Formatters.longDuration(group.duration))")
                            .font(.system(size: 13))
                            .foregroundColor(.boxSecondaryText)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
