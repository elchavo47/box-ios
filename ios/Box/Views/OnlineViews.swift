import SwiftUI

// MARK: - Ortak

extension LibraryStore {
    /// YouTube sonuçlarını çalınabilir şarkılara çevirir (indirilmişse yerel dosya).
    func playable(_ results: [SearchResult]) -> [Track] {
        results.map { localTrack(for: $0) ?? .remote($0) }
    }
}

/// YouTube sonucu satırı: satıra dokununca dinler, sağdaki düğme indirir.
struct OnlineResultRow: View {
    let result: SearchResult
    let onPlay: () -> Void

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var stream: StreamCache

    private var isCurrent: Bool { player.current?.remote?.id == result.id || (player.current.map { library.localTrack(for: result)?.id == $0.id } ?? false) }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ZStack {
                        RemoteThumb(url: URL(string: "https://i.ytimg.com/vi/\(result.id)/mqdefault.jpg"))
                            .frame(width: 112, height: 63)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.5))
                                .frame(width: 112, height: 63)
                            if player.isBuffering { ProgressView().tint(.white) } else { PlayingBars(animating: player.isPlaying) }
                        } else if stream.preparing.contains(result.id) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.5))
                                .frame(width: 112, height: 63)
                            ProgressView().tint(.white)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if result.duration > 0 && !isCurrent {
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
                            .foregroundColor(isCurrent ? .accent : .white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(result.channel)
                            .font(.system(size: 13))
                            .foregroundColor(.boxSecondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .contextMenu { OnlineContextItems(result: result) }

            Button {
                if library.localTrack(for: result) == nil {
                    downloads.download(result)
                    Haptics.tap()
                }
            } label: {
                DownloadIndicator(state: downloads.state(for: result.id), downloaded: library.localTrack(for: result) != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(library.localTrack(for: result) != nil ? "İndirildi" : "İndir")
        }
    }
}

struct OnlineContextItems: View {
    let result: SearchResult
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        let track = library.localTrack(for: result) ?? .remote(result)
        Button { player.play([track]) } label: { Label("Dinle", systemImage: "play.fill") }
        Button { player.playNext(track) } label: { Label("Sıradaki olarak çal", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(track) } label: { Label("Sıraya ekle", systemImage: "text.append") }
        if library.localTrack(for: result) == nil {
            Button { downloads.download(result) } label: { Label("Kitaplığa indir", systemImage: "arrow.down.circle") }
        }
    }
}

struct DownloadIndicator: View {
    let state: DownloadState?
    let downloaded: Bool

    var body: some View {
        ZStack {
            if downloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accent)
            } else {
                switch state {
                case .none:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 25, weight: .light))
                        .foregroundColor(.white)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 25, weight: .light))
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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accent)
                }
            }
        }
        .frame(width: 40, height: 44)
        .contentShape(Rectangle())
    }
}

/// Ana sayfadaki yatay öneri kartı.
struct RemoteCard: View {
    let result: SearchResult
    var size: CGFloat = 150
    let onPlay: () -> Void

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteThumb(url: URL(string: "https://i.ytimg.com/vi/\(result.id)/mqdefault.jpg"))
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if player.current?.remote?.id == result.id {
                        PlayingBars(animating: player.isPlaying)
                            .padding(10)
                    } else if library.localTrack(for: result) != nil {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.accent)
                            .background(Circle().fill(Color.black))
                            .padding(8)
                    }
                }
                Text(result.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(result.channel)
                    .font(.system(size: 12))
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
        .contextMenu { OnlineContextItems(result: result) }
    }
}

// MARK: - Tür sayfası

struct GenreView: View {
    let genre: FeedGenre

    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var stream: StreamCache

    @State private var results: [SearchResult] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 80)
                } else if let error {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "Yüklenemedi", message: error, actionTitle: "Tekrar dene") {
                        Task { await load() }
                    }
                } else {
                    HStack(spacing: 10) {
                        Button { player.play(library.playable(results), startAt: 0) } label: { Label("Dinle", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button { player.play(library.playable(results), startAt: 0, shuffled: true) } label: { Label("Karıştır", systemImage: "shuffle") }
                            .buttonStyle(PrimaryButtonStyle(filled: false))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        OnlineResultRow(result: result) {
                            player.play(library.playable(results), startAt: index)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .boxScreenBackground()
        .navigationTitle(genre.title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { downloads.download(all: results) } label: { Label("Hepsini indir", systemImage: "arrow.down.circle") }
                        .disabled(results.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { if results.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            results = try await feed.genre(genre.key, token: auth.token).results
            stream.warm(results, limit: 4)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Bir sorun oldu."
        }
        loading = false
    }
}

// MARK: - YouTube listesi içe aktarma

struct PlaylistImportView: View {
    var initialLink = ""

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var playlist: YouTubePlaylist?
    @State private var loading = false
    @State private var error: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let playlist {
                        preview(playlist)
                    } else {
                        intro
                    }
                }
                .padding(16)
            }
            .background(Color.boxSurface.ignoresSafeArea())
            .navigationTitle("YouTube listesi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            if !initialLink.isEmpty, link.isEmpty {
                link = initialLink
                Task { await fetch() }
            } else if link.isEmpty, let clip = UIPasteboard.general.string, clip.contains("list=") {
                link = clip
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YouTube veya YouTube Music'teki bir çalma listesinin bağlantısını yapıştır. Liste Box'a eklenir; şarkıları indirmeden dinleyebilir ya da tek dokunuşla hepsini indirebilirsin.")
                .font(.subheadline)
                .foregroundColor(.boxSecondaryText)

            HStack(spacing: 10) {
                Image(systemName: "link").foregroundColor(.boxSecondaryText)
                TextField("https://youtube.com/playlist?list=…", text: $link)
                    .focused($focused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await fetch() } }
                Button("Yapıştır") {
                    if let clip = UIPasteboard.general.string { link = clip }
                }
                .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.boxSurface2))

            if let error {
                Text(error).font(.subheadline).foregroundColor(.orange)
            }

            Button {
                Task { await fetch() }
            } label: {
                if loading { ProgressView().tint(.black) } else { Text("Listeyi getir") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || loading)

            VStack(alignment: .leading, spacing: 6) {
                Label("YouTube uygulamasında listeyi aç › Paylaş › Bağlantıyı kopyala", systemImage: "1.circle")
                Label("Box'a dön, bağlantı kendiliğinden gelir", systemImage: "2.circle")
                Label("Gizli listeler ve otomatik \"Mix\" listeleri desteklenmez", systemImage: "info.circle")
            }
            .font(.footnote)
            .foregroundColor(.boxSecondaryText)
            .padding(.top, 6)
        }
    }

    private func preview(_ list: YouTubePlaylist) -> some View {
        let tracks = library.playable(list.items)
        let missing = list.items.filter { library.localTrack(for: $0) == nil }

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                RemoteThumb(url: list.items.first.flatMap { URL(string: "https://i.ytimg.com/vi/\($0.id)/mqdefault.jpg") })
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Text("\(list.channel) • \(list.items.count) şarkı").font(.subheadline).foregroundColor(.boxSecondaryText)
                    if missing.count < list.items.count {
                        Text("\(list.items.count - missing.count) tanesi zaten kitaplığında").font(.footnote).foregroundColor(.accent)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    save(list)
                    player.play(tracks, startAt: 0)
                    dismiss()
                } label: { Label("Dinle", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    save(list)
                    player.play(tracks, startAt: 0, shuffled: true)
                    dismiss()
                } label: { Label("Karıştır", systemImage: "shuffle") }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
            }

            Button {
                save(list)
                downloads.download(all: missing)
                Haptics.success()
                dismiss()
            } label: {
                Label(missing.isEmpty ? "Hepsi indirilmiş" : "Kaydet ve \(missing.count) şarkıyı indir", systemImage: "arrow.down.circle")
            }
            .buttonStyle(PrimaryButtonStyle(filled: false))
            .disabled(missing.isEmpty)

            Button {
                save(list)
                Haptics.success()
                dismiss()
            } label: {
                Label(saved ? "Kaydedildi" : "Sadece Box listesi olarak kaydet", systemImage: "text.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle(filled: false))

            Divider().background(Color.boxStroke)

            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                OnlineResultRow(result: item) {
                    player.play(tracks, startAt: index)
                }
            }
        }
    }

    private func save(_ list: YouTubePlaylist) {
        guard !saved else { return }
        library.importPlaylist(list)
        saved = true
    }

    private func fetch() async {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let token = auth.token else { return }
        focused = false
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: PlaylistResponse = try await APIClient.shared.send("playlist", query: ["url": text], token: token)
            if response.playlist.items.isEmpty {
                error = "Listede çalınabilir şarkı bulunamadı."
            } else {
                playlist = response.playlist
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Liste alınamadı."
        }
    }
}
