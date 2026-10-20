import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var history: SearchHistory
    @EnvironmentObject private var router: AppRouter

    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var scope: Scope = .online
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    enum Scope: String, CaseIterable, Hashable {
        case online = "YouTube"
        case local = "Kitaplığım"
    }

    private var activeScope: Scope { auth.isPremium ? scope : .local }

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
                        if submitted.isEmpty && !(activeScope == .local && !query.isEmpty) {
                            idleContent
                        } else {
                            if auth.isPremium {
                                ChipBar(items: Scope.allCases, selection: $scope) { $0.rawValue }
                                    .padding(.bottom, 12)
                            }
                            if activeScope == .online { onlineResults } else { localList }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .boxScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
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
        if !downloads.sortedItems.isEmpty {
            HStack {
                Text("İndirmeler")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
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
                    .onTapGesture { playDownloaded(item) }
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
                    ? "Şarkı ya da sanatçı ara, beğendiğini tek dokunuşla indir. İndirilenler internetsiz çalar."
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

    @ViewBuilder
    private var onlineResults: some View {
        if isSearching {
            ForEach(0..<6, id: \.self) { _ in SkeletonRow().padding(.horizontal, 16).padding(.vertical, 6) }
        } else if let errorMessage {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Bir sorun oldu", message: errorMessage, actionTitle: "Tekrar dene") {
                submit(submitted)
            }
        } else if results.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "Sonuç yok", message: "Başka bir şey aramayı dene.")
        } else {
            if let quota = auth.quota, let left = quota.downloadsLeft {
                Text("Bugün \(left) indirme hakkın kaldı")
                    .font(.footnote)
                    .foregroundColor(.boxSecondaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            ForEach(results) { result in
                SearchResultRow(result: result, state: downloads.state(for: result.id), downloaded: isDownloaded(result)) {
                    tap(result)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
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
                let response: SearchResponse = try await APIClient.shared.send("search", query: ["q": trimmed], token: token)
                guard !Task.isCancelled else { return }
                results = response.results
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Arama yapılamadı."
                if (error as? APIError)?.status == 403 { await auth.refresh() }
            }
        }
    }

    private func tap(_ result: SearchResult) {
        history.add(result: result)
        if let track = downloadedTrack(result) {
            player.play([track])
            return
        }
        if downloads.state(for: result.id)?.isActive == true { return }
        downloads.download(result)
        Haptics.tap()
    }

    private func isDownloaded(_ result: SearchResult) -> Bool {
        downloadedTrack(result) != nil
    }

    private func downloadedTrack(_ result: SearchResult) -> Track? {
        if case .done(let path) = downloads.state(for: result.id), let track = library.track(forPath: path) {
            return track
        }
        let name = FileService.sanitize(result.title)
        let path = AppConfig.downloadsFolderName + "/" + name + ".m4a"
        return library.track(forPath: path)
    }

    private func playDownloaded(_ item: DownloadItem) {
        guard case .done(let path) = item.state, let track = library.track(forPath: path) else { return }
        player.play([track])
    }
}

// MARK: - Satırlar

struct RemoteThumb: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ArtworkPlaceholder()
            }
        }
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

private struct SearchResultRow: View {
    let result: SearchResult
    let state: DownloadState?
    let downloaded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RemoteThumb(url: result.thumbnailURL)
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if result.duration > 0 {
                            Text(Formatters.time(Double(result.duration)))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(result.channel)
                        .font(.system(size: 13))
                        .foregroundColor(.boxSecondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DownloadIndicator(state: state, downloaded: downloaded)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

private struct DownloadIndicator: View {
    let state: DownloadState?
    let downloaded: Bool

    var body: some View {
        ZStack {
            if downloaded {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accent)
            } else {
                switch state {
                case .none:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(.white)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(.orange)
                case .preparing, .processing:
                    ProgressView().tint(.white)
                case .downloading(let progress):
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Color.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: progress)
                case .done:
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accent)
                }
            }
        }
        .frame(width: 32, height: 32)
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
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        if case .failed = item.state { return .orange }
        if case .done = item.state { return .accent }
        return .boxSecondaryText
    }
}
