import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var history: SearchHistory
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var stream: StreamCache
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var feed: FeedStore

    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [SearchResult] = []
    @State private var topArtist: ArtistCard?
    @State private var top: MusicItem?
    @State private var items: [MusicItem] = []
    @State private var kindItems: [SearchFilter: [MusicItem]] = [:]
    @State private var kindLoading: SearchFilter?
    @State private var kindError: String?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var filter: SearchFilter = .all
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @State private var showImport = false
    @State private var suggestions: [String] = []
    @State private var importLink = ""

    private var activeFilter: SearchFilter { auth.isPremium ? filter : .library }

    private var localResults: [Track] {
        let text = (submitted.isEmpty ? query : submitted).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(text)
                || $0.artist.localizedCaseInsensitiveContains(text)
                || $0.album.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if submitted.isEmpty && !(activeFilter == .library && !query.isEmpty) {
                            idleContent
                        } else {
                            if auth.isPremium {
                                ChipBar(items: SearchFilter.allCases, selection: $filter) { $0.title }
                                    .padding(.bottom, 12)
                            }
                            switch activeFilter {
                            case .library: localList
                            case .all: onlineResults
                            case .songs: songResults
                            default: kindResults(activeFilter)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .boxScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard auth.isPremium, settings.searchSuggestions, submitted.isEmpty, text.count >= 2, network.isOnline else {
                    suggestions = []
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                suggestions = await feed.suggestions(for: text, token: auth.token)
            }
            .sheet(isPresented: $showImport) {
                PlaylistImportView(initialLink: importLink)
            }
            .onChange(of: filter) { value in loadKind(value) }
        }
    }

    // MARK: Arama çubuğu

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                if focused || !query.isEmpty {
                    Button {
                        query = ""
                        submitted = ""
                        results = []
                        top = nil
                        items = []
                        kindItems = [:]
                        errorMessage = nil
                        focused = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Geri")
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.boxSecondaryText)
                }

                TextField(auth.isPremium ? "Şarkı, sanatçı ara" : "Kitaplığında ara", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { submit(query) }
                    .onChange(of: query) { text in
                        if text.isEmpty { submitted = ""; results = []; errorMessage = nil }
                        else if focused, !submitted.isEmpty, text.trimmingCharacters(in: .whitespaces) != submitted { submitted = "" }
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.boxSecondaryText)
                    }
                    .accessibilityLabel("Temizle")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Capsule().fill(Color.boxSurface2))

            if !focused {
                AccountButton()
            }
        }
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    // MARK: Boş durum: geçmiş ve indirmeler

    @ViewBuilder
    private var idleContent: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty && !suggestions.isEmpty {
            ForEach(suggestions, id: \.self) { item in
                HStack(spacing: 18) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 28)
                    Text(item)
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        query = item + " "
                    } label: {
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 40, height: 44)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 50)
                .contentShape(Rectangle())
                .onTapGesture {
                    query = item
                    submit(item)
                }
            }
            Divider().background(Color.boxStroke).padding(.vertical, 8)
        }
        OfflineBanner().padding(.bottom, 12)
        if auth.isPremium && !downloads.sortedItems.isEmpty {
            HStack {
                Text("İndirmeler")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if downloads.failedCount > 0 {
                    Button("Tekrar dene (\(downloads.failedCount))") { downloads.retryFailed() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.trailing, 10)
                }
                if downloads.sortedItems.contains(where: { !$0.state.isActive }) {
                    Button("Temizle") { downloads.clearFinished() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.boxSecondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 6)

            ForEach(downloads.sortedItems) { item in
                DownloadRow(item: item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if case .failed = item.state {
                            downloads.download(SearchResult(id: item.id, title: item.title, channel: item.channel, thumbnail: item.thumbnail?.absoluteString, duration: 0))
                        } else {
                            playDownloaded(item)
                        }
                    }
            }
            Spacer().frame(height: 18)
        }

        if auth.isPremium && !history.results.isEmpty {
            Text("Son aramalar")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.boxSecondaryText)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(history.results) { result in
                        Button {
                            tap(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteThumb(url: result.thumbnailURL)
                                    .frame(width: 128, height: 128)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(alignment: .bottomTrailing) {
                                        if isDownloaded(result) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(.accent)
                                                .background(Circle().fill(Color.black))
                                                .padding(6)
                                        }
                                    }
                                Text(result.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            .frame(width: 128)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 14)
        }

        ForEach(history.queries, id: \.self) { item in
            HStack(spacing: 18) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 28)
                Text(item)
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    query = item
                    focused = true
                } label: {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 40, height: 44)
                }
                .accessibilityLabel("Aramaya taşı")
                Button {
                    withAnimation { history.remove(query: item) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 36, height: 44)
                }
                .accessibilityLabel("Geçmişten sil")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 54)
            .contentShape(Rectangle())
            .onTapGesture {
                query = item
                submit(item)
            }
            .contextMenu {
                Button(role: .destructive) { history.remove(query: item) } label: { Label("Geçmişten sil", systemImage: "trash") }
            }
        }

        if history.queries.isEmpty && history.results.isEmpty && downloads.sortedItems.isEmpty {
            EmptyStateView(
                icon: auth.isPremium ? "magnifyingglass" : "music.note.list",
                title: auth.isPremium ? "Ne dinlemek istersin?" : "Kitaplığında ara",
                message: auth.isPremium
                    ? "Şarkı ya da sanatçı ara; dokun ve hemen dinle, istersen indir."
                    : "Şarkı, sanatçı ya da albüm adı yaz."
            )
            .padding(.top, 40)
        } else if !history.queries.isEmpty {
            Button("Arama geçmişini temizle") { history.clear() }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.boxSecondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
    }

    // MARK: Sonuçlar

    /// Şarkılar (oynatma sırası için): en iyi sonuç kartındakiler ve diğer sonuçlardaki şarkılar.
    private var songItems: [MusicItem] {
        var list: [MusicItem] = []
        var seen = Set<String>()
        for item in (top.map { [$0] + ($0.children ?? []) } ?? []) + items where item.type == .song {
            if seen.insert(item.itemID).inserted { list.append(item) }
        }
        return list
    }

    @ViewBuilder
    private var quotaLine: some View {
        if let quota = auth.quota, let left = quota.downloadsLeft {
            Text("Bugün \(left) indirme hakkın kaldı")
                .font(.footnote)
                .foregroundColor(.boxSecondaryText)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var onlineResults: some View {
        if isSearching {
            ForEach(0..<6, id: \.self) { _ in SkeletonRow().padding(.horizontal, 16).padding(.vertical, 6) }
        } else if let errorMessage {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Bir sorun oldu", message: errorMessage, actionTitle: "Tekrar dene") {
                submit(submitted)
            }
        } else if top == nil && items.isEmpty && results.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "Sonuç yok", message: "Başka bir şey aramayı dene.")
        } else if top != nil || !items.isEmpty {
            quotaLine
            if let top {
                TopResultCard(item: top, songs: songItems, open: open, play: play)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
            let others = items.filter { item in !(top?.children ?? []).contains(where: { $0.id == item.id }) }
            if !others.isEmpty {
                Text(top == nil ? "Sonuçlar" : "Diğer sonuçlar")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                ForEach(others) { item in
                    MusicResultRow(item: item) { open(item) }
                        .padding(.leading, 16)
                        .padding(.trailing, 6)
                        .padding(.vertical, 6)
                }
            }
        } else {
            // Eski sunucu: yalnızca şarkılar (+ sanatçı).
            quotaLine
            if let topArtist {
                TopArtistRow(artist: topArtist)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            songResults
        }
    }

    @ViewBuilder
    private var songResults: some View {
        if isSearching {
            ForEach(0..<6, id: \.self) { _ in SkeletonRow().padding(.horizontal, 16).padding(.vertical, 6) }
        } else if results.isEmpty {
            EmptyStateView(icon: "music.note", title: "Şarkı bulunamadı", message: errorMessage ?? "Başka bir şey aramayı dene.")
        } else {
            let songs = results.map(MusicItem.song)
            HStack(spacing: 10) {
                Button { play(songs, nil, false) } label: { Label("Hepsini dinle", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { play(songs, nil, true) } label: { Label("Karıştır", systemImage: "shuffle") }
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            ForEach(songs) { item in
                MusicResultRow(item: item) { play(songs, item, false) }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func kindResults(_ kind: SearchFilter) -> some View {
        if kindLoading == kind {
            ForEach(0..<6, id: \.self) { _ in SkeletonRow().padding(.horizontal, 16).padding(.vertical, 6) }
        } else if let list = kindItems[kind], !list.isEmpty {
            ForEach(list) { item in
                MusicResultRow(item: item) { open(item, in: list) }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
            }
        } else if let kindError {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Yüklenemedi", message: kindError, actionTitle: "Tekrar dene") {
                kindItems[kind] = nil
                loadKind(kind)
            }
        } else if kindItems[kind] != nil {
            EmptyStateView(icon: "magnifyingglass", title: "Sonuç yok", message: "Bu türde sonuç bulunamadı.")
        }
    }

    @ViewBuilder
    private var localList: some View {
        let tracks = localResults
        if tracks.isEmpty {
            EmptyStateView(icon: "music.note", title: "Kitaplığında yok", message: auth.isPremium ? "YouTube sekmesinde aramayı dene." : "Başka bir şey aramayı dene.")
        }
        ForEach(tracks) { track in
            TrackRow(track: track)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .onTapGesture { player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0) }
        }
    }

    // MARK: İşlemler

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if auth.isPremium, trimmed.contains("list="), trimmed.lowercased().contains("youtu") {
            importLink = trimmed
            showImport = true
            query = ""
            focused = false
            return
        }
        submitted = trimmed
        focused = false
        history.add(query: trimmed)
        guard auth.isPremium, let token = auth.token else { return }

        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task { @MainActor in
            defer { if !Task.isCancelled { isSearching = false } }
            do {
                let response: SearchResponse = try await APIClient.shared.send("search", query: ["q": trimmed, "mode": "all"], token: token)
                guard !Task.isCancelled else { return }
                results = response.results
                topArtist = response.artist
                top = response.top
                items = response.items ?? []
                kindItems = [:]
                kindError = nil
                let first = ([response.top].compactMap { $0 } + (response.top?.children ?? []) + (response.items ?? [])).compactMap(\.result)
                stream.warm(first.isEmpty ? response.results : first, limit: 5)
                loadKind(filter)
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                topArtist = nil
                top = nil
                items = []
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Arama yapılamadı."
                if (error as? APIError)?.status == 403 { await auth.refresh() }
            }
        }
    }

    /// Son aramalardan dokunulunca: indirildiyse yerelden, değilse internetten çalar.
    private func tap(_ result: SearchResult) {
        history.add(result: result)
        player.play([library.localTrack(for: result) ?? .remote(result)])
    }

    private func isDownloaded(_ result: SearchResult) -> Bool {
        library.localTrack(for: result) != nil
    }

    /// Şarkıları çalar (indirilmiş olanlar yerelden).
    private func play(_ list: [MusicItem], _ start: MusicItem?, _ shuffled: Bool) {
        let playable = list.filter(\.isPlayable)
        let tracks = playable.compactMap(\.result).map { library.localTrack(for: $0) ?? .remote($0) }
        guard !tracks.isEmpty else { return }
        let index = start.flatMap { s in playable.firstIndex { $0.itemID == s.itemID } } ?? 0
        if let result = start?.result { history.add(result: result) }
        player.play(tracks, startAt: index, shuffled: shuffled)
    }

    /// Satıra dokununca: şarkı/video çalar, albüm ve sanatçı sayfasını, listeyi açar.
    private func open(_ item: MusicItem) {
        open(item, in: songItems.isEmpty ? [item] : songItems)
    }

    private func open(_ item: MusicItem, in list: [MusicItem]) {
        switch item.type {
        case .song:
            play(list.contains(where: { $0.itemID == item.itemID }) ? list : [item] + list, item, false)
        case .video:
            play([item], item, false)
        case .artist:
            router.openMusic(.artist(id: item.itemID, name: item.title))
        case .album:
            router.openMusic(.album(id: item.itemID, name: item.title, artist: item.channel ?? ""))
        case .playlist:
            importLink = "https://music.youtube.com/playlist?list=" + item.itemID
            showImport = true
        case .other:
            break
        }
    }

    /// Filtre çipi seçilince o türün sonuçlarını getirir (bir kez; aynı aramada önbellekte kalır).
    private func loadKind(_ kind: SearchFilter) {
        guard let server = kind.serverFilter, !submitted.isEmpty, kindItems[kind] == nil, let token = auth.token else { return }
        let text = submitted
        kindLoading = kind
        kindError = nil
        Task { @MainActor in
            defer { if kindLoading == kind { kindLoading = nil } }
            do {
                let response: SearchResponse = try await APIClient.shared.send("search", query: ["q": text, "filter": server], token: token)
                guard text == submitted else { return }
                kindItems[kind] = response.items ?? response.results.map(MusicItem.song)
            } catch {
                guard text == submitted else { return }
                kindError = (error as? LocalizedError)?.errorDescription ?? "Sonuçlar alınamadı."
            }
        }
    }

    private func playDownloaded(_ item: DownloadItem) {
        guard case .done(let path) = item.state, let track = library.track(forPath: path) else { return }
        player.play([track])
    }
}

// MARK: - Satırlar

struct RemoteThumb: View {
    let url: URL?
    /// Piksel cinsinden en uzun kenar.
    var maxSide: CGFloat = 480

    var body: some View {
        CachedRemoteImage(url: url, maxSide: maxSide) { ArtworkPlaceholder() }
            .clipped()
    }
}

private struct SkeletonRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).frame(height: 13)
                RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 11)
            }
        }
        .foregroundColor(Color.white.opacity(pulse ? 0.1 : 0.05))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            RemoteThumb(url: item.thumbnail)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                if case .downloading(let progress) = item.state {
                    ProgressView(value: progress)
                        .tint(.accent)
                        .scaleEffect(x: 1, y: 0.8)
                } else {
                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundColor(statusColor)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch item.state {
            case .preparing, .processing:
                ProgressView().tint(.white)
            case .downloading(let progress):
                Text(verbatim: "%\(Int(progress * 100))")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
            case .done:
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.accent)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
            }
        }
    }

    private var statusText: String {
        switch item.state {
        case .preparing: return "Hazırlanıyor… (biraz sürebilir)"
        case .downloading: return "İndiriliyor"
        case .processing: return "Kitaplığa ekleniyor"
        case .done: return "Kitaplıkta • çalmak için dokun"
        case .failed(let message): return message + " • tekrar denemek için dokun"
        }
    }

    private var statusColor: Color {
        if case .failed = item.state { return .orange }
        if case .done = item.state { return .accent }
        return .boxSecondaryText
    }
}
