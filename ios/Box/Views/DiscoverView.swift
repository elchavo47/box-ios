import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var lastQuery = ""

    var body: some View {
        NavigationStack {
            List {
                if !downloads.sortedItems.isEmpty {
                    Section {
                        ForEach(downloads.sortedItems) { item in
                            DownloadRow(item: item)
                                .listRowBackground(Color.boxCard)
                                .onTapGesture { playDownloaded(item) }
                        }
                    } header: {
                        HStack {
                            Text("İndirmeler")
                            Spacer()
                            if downloads.sortedItems.contains(where: { !$0.state.isActive }) {
                                Button("Temizle") { downloads.clearFinished() }
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }

                Section {
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView().tint(.neon)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else if let errorMessage {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Bir sorun oldu", message: errorMessage)
                            .listRowBackground(Color.clear)
                    } else if results.isEmpty {
                        EmptyStateView(
                            icon: lastQuery.isEmpty ? "sparkle.magnifyingglass" : "magnifyingglass",
                            title: lastQuery.isEmpty ? "Ne dinlemek istersin?" : "Sonuç yok",
                            message: lastQuery.isEmpty
                                ? "Şarkı ya da sanatçı ara, beğendiğini tek dokunuşla kitaplığına indir."
                                : "Başka bir şey aramayı dene."
                        )
                        .listRowBackground(Color.clear)
                    }

                    ForEach(results) { result in
                        SearchResultRow(result: result, state: downloads.state(for: result.id)) {
                            downloads.download(result)
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    if !results.isEmpty {
                        Text("Sonuçlar")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .navigationTitle("Keşfet")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Şarkı veya sanatçı ara")
            .onSubmit(of: .search) {
                Task { await search() }
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let token = auth.token else { return }

        isSearching = true
        errorMessage = nil
        lastQuery = text
        defer { isSearching = false }

        do {
            let response: SearchResponse = try await APIClient.shared.send("search", query: ["q": text], token: token)
            results = response.results
        } catch {
            results = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Arama yapılamadı."
            if (error as? APIError)?.status == 403 {
                await auth.refresh()
            }
        }
    }

    private func playDownloaded(_ item: DownloadItem) {
        guard case .done(let path) = item.state, let track = library.track(forPath: path) else { return }
        player.play([track])
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let state: DownloadState?
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Color.boxCard
                        Image(systemName: "music.note").foregroundColor(.neon.opacity(0.7))
                    }
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if result.duration > 0 {
                    Text(Formatters.time(Double(result.duration)))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                Text(result.channel)
                    .font(.caption)
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            DownloadButton(state: state, action: onDownload)
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadButton: View {
    let state: DownloadState?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .none, .failed:
                    Image(systemName: state == nil ? "arrow.down.circle" : "arrow.clockwise.circle")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(state == nil ? .neon : .orange)
                case .preparing, .processing:
                    ProgressView().tint(.neon)
                case .downloading(let progress):
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Color.neon, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: .neon.opacity(0.7), radius: 4)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.neon)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderless)
        .disabled(state?.isActive == true || isDone)
    }

    private var isDone: Bool {
        if case .done = state { return true }
        return false
    }
}

private struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.thumbnail) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Color.boxCardHighlight
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
                    .lineLimit(2)
            }

            Spacer()

            switch item.state {
            case .preparing, .processing:
                ProgressView().tint(.neon)
            case .downloading(let progress):
                Text(verbatim: "%\(Int(progress * 100))")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundColor(.neon)
            case .done:
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.neon)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
            }
        }
    }

    private var statusText: String {
        switch item.state {
        case .preparing: return "Hazırlanıyor… (biraz sürebilir)"
        case .downloading: return "İndiriliyor"
        case .processing: return "Kitaplığa ekleniyor"
        case .done: return "Kitaplıkta • İndirilenler klasörü"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        if case .failed = item.state { return .orange }
        if case .done = item.state { return .neon }
        return .boxSecondaryText
    }
}
