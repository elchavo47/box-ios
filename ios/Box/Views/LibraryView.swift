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
    @EnvironmentObject private var router: AppRouter
    @State private var exportSelection: ExportSelection?
    @State private var deleteTarget: Playlist?

    struct ExportSelection: Identifiable {
        let id = UUID()
        let items: Set<ExportItem>
    }

    @State private var path = NavigationPath()
    @State private var showImport = false
    @State private var showListFile = false
    @State private var importMessage: String?
    @State private var section: LibSection = .playlists
    @State private var searchText = ""
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @AppStorage("box.sort") private var sort: TrackSort = .title
    @State private var editMode: EditMode = .inactive
    /// Toplu seçim (Şarkılar bölümü)
    @State private var bulkMode = false
    @State private var picked: Set<String> = []
    @State private var confirmBulkDelete = false

    private func deleteWithUndo(_ id: UUID) {
        guard let removed = library.deletePlaylistUndoable(id) else { return }
        Haptics.soft()
        let store = library
        router.show(L("Liste silindi"), icon: "trash.fill", actionTitle: L("Geri al")) {
            store.restorePlaylist(removed)
            Haptics.success()
        }
    }

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
                ChipBar(items: LibSection.allCases, selection: $section) { L($0.rawValue) }
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
            .environment(\.editMode, $editMode)
            .onChange(of: section) { _ in editMode = .inactive; endBulk() }
            .boxScreenBackground()
            .navigationTitle(L("Kitaplık"))
            .searchable(text: $searchText, prompt: L("Kitaplığında ara"))
            .onChange(of: searchText) { text in
                if !text.isEmpty && section == .playlists { section = .songs }
            }
            .refreshable { await library.refresh() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bulkMode && section == .songs { bulkBar }
            }
            .boxConfirm(
                L("{0} şarkı silinsin mi?", picked.count),
                isPresented: $confirmBulkDelete,
                icon: "trash",
                message: L("Dosyalar cihazından silinir. Bu işlem geri alınamaz."),
                confirmTitle: L("Sil")
            ) { deletePicked() }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if library.isScanning {
                        ProgressView().tint(.white)
                    }
                    if section == .songs {
                        if !library.tracks.isEmpty {
                            Button(bulkMode ? L("Bitti") : L("Seç")) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if bulkMode { endBulk() } else { bulkMode = true }
                                }
                            }
                        }
                        Menu {
                            Picker(L("Sırala"), selection: $sort) {
                                ForEach(TrackSort.allCases) { option in
                                    Text(L(option.rawValue)).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                    if section == .playlists {
                        Menu {
                            Button { showNewPlaylist = true } label: { Label(L("Yeni çalma listesi"), systemImage: "plus") }
                            if auth.has(.playlist) {
                                Button { showImport = true } label: { Label(L("YouTube / Spotify listesi içe aktar"), systemImage: "square.and.arrow.down.on.square") }
                            }
                            Button { showListFile = true } label: { Label(L("Liste dosyası aç (.boxlist)"), systemImage: "doc.badge.plus") }
                            Button { exportSelection = ExportSelection(items: []) } label: { Label(L("Listeleri dışa aktar"), systemImage: "square.and.arrow.up") }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L("Liste ekle"))
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
                if let lists = SharedListFile.read(from: url), !lists.isEmpty {
                    router.importRequest = ImportRequest(lists: lists)
                } else {
                    importMessage = L("Bu dosya bir Box listesi değil.")
                }
            }
            .sheet(item: $exportSelection) { selection in
                ListExportView(preselected: selection.items)
            }
            .boxConfirm(
                deleteTarget.map { L("\"{0}\" silinsin mi?", $0.name) } ?? "",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                icon: "trash",
                message: L("Şarkılar silinmez."),
                confirmTitle: L("Listeyi sil")
            ) {
                if let target = deleteTarget { deleteWithUndo(target.id) }
            }
            .onChange(of: router.openPlaylist) { id in
                guard let id else { return }
                router.openPlaylist = nil
                section = .playlists
                path = NavigationPath()
                path.append(HomeRoute.playlist(id))
            }
            .alert(L("İçe aktarma"), isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button(L("Tamam"), role: .cancel) {}
            } message: { Text(importMessage ?? "") }
            .alert(L("Yeni çalma listesi"), isPresented: $showNewPlaylist) {
                TextField(L("Liste adı"), text: $newPlaylistName)
                Button(L("Oluştur")) {
                    let playlist = library.createPlaylist(name: newPlaylistName.trimmingCharacters(in: .whitespaces))
                    newPlaylistName = ""
                    path.append(HomeRoute.playlist(playlist.id))
                }
                Button(L("Vazgeç"), role: .cancel) { newPlaylistName = "" }
            }
        }
    }

    // MARK: Toplu seçim

    private func endBulk() {
        bulkMode = false
        picked = []
    }

    private var pickedTracks: [Track] {
        library.tracks.filter { picked.contains($0.id) }
    }

    private var bulkBar: some View {
        let visible = sortedTracks
        return BulkBar(count: picked.count, total: visible.count) {
            if picked.count == visible.count { picked = [] } else { picked = Set(visible.map(\.id)) }
            Haptics.tap()
        } actions: {
            BulkAddToPlaylist(tracks: pickedTracks) { endBulk() }
            Button {
                let list = pickedTracks
                for item in list { player.addToQueue(item) }
                Haptics.success()
                router.show(L("{0} şarkı sıraya eklendi", list.count), icon: "text.append")
                endBulk()
            } label: {
                BulkActionLabel(title: L("Sıraya ekle"), icon: "text.append")
            }
            Button { confirmBulkDelete = true } label: {
                BulkActionLabel(title: L("Sil"), icon: "trash", destructive: true)
            }
        }
    }

    private func deletePicked() {
        let list = pickedTracks
        guard !list.isEmpty else { return }
        if let current = player.current, picked.contains(current.id) { player.next() }
        for track in list {
            try? FileService.delete(track.url)
            library.pathDeleted(track.url)
        }
        Haptics.soft()
        router.show(L("{0} şarkı silindi", list.count), icon: "trash.fill")
        endBulk()
        Task { await library.refresh() }
    }

    // MARK: Bölümler

    @ViewBuilder
    private var playlists: some View {
        // 1) En üstte kendi listelerin: basılı tutup sürükleyerek sıralanır.
        HStack {
            Text(L("Listelerim"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            if library.playlists.count > 1 {
                Button(editMode == .active ? L("Bitti") : L("Sırala")) {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accent)
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 2)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(true)

        if library.playlists.isEmpty {
            Button {
                showNewPlaylist = true
            } label: {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundColor(.white))
                    Text(L("İlk listeni oluştur"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        ForEach(library.playlists) { playlist in
            let tracks = library.tracks(for: playlist)
            playlistRow(title: playlist.name, subtitle: playlistSubtitle(playlist, count: tracks.count), route: .playlist(playlist.id)) {
                PlaylistArtwork(playlist: playlist, tracks: tracks, size: 56, cornerRadius: 0)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    deleteTarget = playlist
                } label: {
                    Label(L("Sil"), systemImage: "trash")
                }
                .tint(.red)
            }
            .swipeActions(edge: .leading) {
                Button {
                    exportSelection = ExportSelection(items: [.playlist(playlist.id)])
                } label: {
                    Label(L("Dışa aktar"), systemImage: "square.and.arrow.up")
                }
                .tint(.accentDeep)
            }
        }
        .onMove { from, to in
            library.movePlaylists(from: from, to: to)
            Haptics.soft()
        }

        if library.playlists.count > 1 && editMode != .active {
            Text(L("Sırasını değiştirmek için listeye basılı tutup sürükle."))
                .font(.footnote)
                .foregroundColor(.boxTertiaryText)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        // 2) İndirilenler, son çalınanlar ve beğenilenler.
        Text(L("Hızlı erişim"))
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(.white)
            .padding(.top, 14)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
        playlistRow(title: L("İndirilenler"), subtitle: L("{0} şarkı", library.downloadedTracks.count), route: .downloads) {
            if library.downloadedTracks.isEmpty {
                ZStack {
                    LinearGradient(colors: [Color.boxSurface2, Color.boxSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundColor(.accent)
                }
            } else {
                PlaylistCover(tracks: library.downloadedTracks, icon: "arrow.down", size: 56, cornerRadius: 0)
            }
        }
        if !library.recentlyPlayed.isEmpty {
            playlistRow(title: L("Son çalınanlar"), subtitle: L("{0} şarkı", library.recentlyPlayed.count), route: .recent) {
                PlaylistCover(tracks: library.recentlyPlayed, icon: "clock", size: 56, cornerRadius: 0)
            }
        }
        playlistRow(title: L("Beğenilenler"), subtitle: L("{0} şarkı", library.favoriteTracks.count), route: .favorites) {
            ZStack {
                LinearGradient(colors: [Color.accentMid, Color.accentDeep.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "heart.fill").foregroundColor(.white)
            }
        }

        // 3) Otomatik listeler: yer kaplamasın diye tek satırda, yana kaydırılır.
        Text(L("Otomatik listeler"))
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(.white)
            .padding(.top, 14)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(SmartList.allCases, id: \.self) { list in
                    let count = list == .mostPlayed ? library.mostPlayed.count : (list == .forgotten ? library.forgotten.count : library.addedThisMonth.count)
                    if count > 0 {
                        autoTile(title: list.title, subtitle: L("{0} şarkı", count), route: .smart(list)) {
                            ZStack {
                                Color.boxSurface2
                                Image(systemName: list.icon).font(.system(size: 30)).foregroundColor(.accent)
                            }
                        }
                    }
                }
                autoTile(title: L("Box Özeti"), subtitle: L("İstatistiklerin"), route: .summary) {
                    ZStack {
                        LinearGradient(colors: [Color.accent, Color(red: 0.62, green: 0.95, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "chart.bar.fill").font(.system(size: 30)).foregroundColor(.black)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func playlistSubtitle(_ playlist: Playlist, count: Int) -> String {
        if playlist.sourceID != nil {
            if count == 0 && !auth.has(.stream) { return L("YouTube listesi • Premium ile dinlenir") }
            return L("YouTube listesi • {0} şarkı", count)
        }
        return L("{0} şarkı", count)
    }

    private func autoTile<Cover: View>(title: String, subtitle: String, route: HomeRoute, @ViewBuilder cover: () -> Cover) -> some View {
        // Liste satırı içinde birden çok bağlantı olduğu için düğmeyle açılıyor (satırın tamamı tek dokunuş sayılmasın).
        Button { path.append(route) } label: {
            VStack(alignment: .leading, spacing: 6) {
                cover()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
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
                title: searchText.isEmpty ? L("Henüz şarkı yok") : L("Sonuç yok"),
                message: searchText.isEmpty ? L("Dosyalar sekmesinden müzik ekle.") : L("\"{0}\" ile eşleşen şarkı bulunamadı.", searchText)
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            HStack(spacing: 10) {
                Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Label(L("Karıştır"), systemImage: "shuffle") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { player.play(tracks, startAt: 0) } label: { Label(L("Çal"), systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Text(L("{0} şarkı • {1}", tracks.count, Formatters.bytes(library.totalSize)))
                .font(.footnote)
                .foregroundColor(.boxSecondaryText)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(tracks) { track in
                SelectableRow(selecting: bulkMode, isSelected: picked.contains(track.id)) {
                    TrackRow(track: track)
                }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 8))
                    .onTapGesture {
                        if bulkMode {
                            if picked.contains(track.id) { picked.remove(track.id) } else { picked.insert(track.id); Haptics.tap() }
                        } else {
                            player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { player.playNext(track) } label: { Label(L("Sıradaki"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(.accentDeep)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { player.addToQueue(track) } label: { Label(L("Sıraya ekle"), systemImage: "text.append") }
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
                title: kind == .artist ? L("Sanatçı yok") : L("Albüm yok"),
                message: kind == .album ? L("Dosyalarında albüm bilgisi olan şarkılar burada gruplanır.") : L("Şarkı ekledikçe sanatçılar burada görünür.")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        ForEach(shown) { group in
            NavigationLink(value: HomeRoute.group(kind: kind, name: group.name)) {
                HStack(spacing: 14) {
                    ArtworkView(url: group.tracks.first?.url, size: 56, cornerRadius: kind == .artist ? 28 : 6, fallback: group.tracks.first?.artworkFallback)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(L("{0} şarkı • {1}", group.tracks.count, Formatters.longDuration(group.duration)))
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
