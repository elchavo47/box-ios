import SwiftUI

@main
struct BoxApp: App {
    @UIApplicationDelegateAdaptor(BoxAppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerManager()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var history = SearchHistory()
    @StateObject private var server = ServerState()
    @StateObject private var router = AppRouter()
    @StateObject private var stream = StreamCache()
    @StateObject private var feed = FeedStore()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var network = NetworkMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        tab.shadowColor = UIColor.white.withAlphaComponent(0.06)
        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(white: 0.62, alpha: 1)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(white: 0.62, alpha: 1), .font: UIFont.systemFont(ofSize: 10, weight: .medium)]
        item.selected.iconColor = .white
        item.selected.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        tab.stackedLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(red: 0.012, green: 0.012, blue: 0.016, alpha: 0.96)
        nav.shadowColor = .clear
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 32, weight: .bold)]
        nav.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = nav.largeTitleTextAttributes
        edge.titleTextAttributes = nav.titleTextAttributes
        UINavigationBar.appearance().scrollEdgeAppearance = edge
        UINavigationBar.appearance().tintColor = .white
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(history)
                .environmentObject(server)
                .environmentObject(router)
                .environmentObject(stream)
                .environmentObject(feed)
                .environmentObject(settings)
                .environmentObject(network)
                .preferredColorScheme(.dark)
                .tint(.accent)
                .task {
                    downloads.attach(library: library, auth: auth)
                    stream.attach(auth: auth)
                    player.onTrackStart = { [weak library] track in library?.recordPlay(track) }
                    player.resolveRemote = { [weak stream] result in
                        guard let stream else { throw APIError(message: "Hazır değil.", status: 0) }
                        return try await stream.resolve(result)
                    }
                    player.liveRemote = { [weak stream] result in
                        guard let stream else { throw APIError(message: "Hazır değil.", status: 0) }
                        return try await stream.liveURL(result)
                    }
                    player.prefetchRemote = { [weak stream] result in stream?.prepareLink(result) }
                    player.videoURLFor = { [weak stream] id in
                        guard let stream else { throw APIError(message: "Hazır değil.", status: 0) }
                        return try await stream.videoURL(id)
                    }
                    player.videoIDFor = { [weak library] track in library?.videoID(forPath: track.relativePath) }
                    player.onStreamCached = { [weak stream] result, temp in stream?.store(result, temp: temp) }
                    player.onRemoteSeen = { [weak library] result in library?.remember(result) }
                    player.radioProvider = { [weak feed, weak auth, weak library] track, exclude in
                        guard let feed, let auth, auth.isPremium, let library else { return [] }
                        let results = await feed.radio(for: track, exclude: exclude, token: auth.token)
                        return library.playable(results)
                    }
                    player.autoRadioEnabled = { [weak auth] in AppSettings.shared.autoRadio && auth?.isPremium == true }
                    player.isPlayable = { [weak stream, weak auth] track in
                        guard let remote = track.remote else { return true }
                        guard auth?.isPremium == true else { return false }
                        return NetworkMonitor.shared.isOnline || stream?.isCached(remote.id) == true
                    }
                    player.allowsRemote = { [weak auth] in auth?.isPremium == true }
                    library.allowsRemote = auth.isPremium
                    player.crossfade = { AppSettings.shared.crossfadeSeconds }
                    player.effects = { (AppSettings.shared.eqPreset, AppSettings.shared.normalizeVolume) }
                    player.visualizer = { AppSettings.shared.visualizer }
                    downloads.network = network
                    player.onListen = { [weak library] track, seconds in library?.addListen(track, seconds: seconds) }
                    PushManager.shared.tokenProvider = { [weak auth] in auth?.token }
                    PushManager.shared.onOpen = { [weak router] target in
                        switch target {
                        case "account": router?.showAccount = true
                        case "search": router?.tab = .search
                        case "library": router?.tab = .library
                        default: router?.tab = .home
                        }
                    }
                    await library.refresh()
                    player.restoreIfNeeded(tracks: library.tracks)
                    // Kaldığı yerden devam eden sırada internet şarkısı varsa ve premium yoksa çıkar.
                    if !auth.isPremium { player.dropRemoteTracks() }
                    await server.refresh()
                    await auth.refresh()
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    switch url.pathExtension.lowercased() {
                    case "boxlist":
                        if let shared = BackupService.read(SharedPlaylist.self, from: url) {
                            library.importShared(shared)
                            router.tab = .library
                        }
                        return
                    case "boxbackup":
                        if let backup = BackupService.read(LibraryBackup.self, from: url) { library.restore(backup) }
                        return
                    default:
                        break
                    }
                    Task {
                        let inbox = library.documents.appendingPathComponent(AppConfig.inboxFolderName, isDirectory: true)
                        await library.importFiles([url], into: inbox)
                    }
                }
                .onChange(of: auth.isPremium) { premium in
                    // Premium kapanınca premium'a ait hiçbir şey kalmasın: internet şarkıları,
                    // video, radyo, bekleyen indirmeler, öneriler.
                    library.allowsRemote = premium
                    if !premium {
                        player.dropRemoteTracks()
                        downloads.cancelAll()
                        feed.reset()
                        history.clear()
                    }
                }
                .onChange(of: auth.user?.id) { id in
                    // Başka bir hesaba geçildiyse önceki hesabın aramaları görünmesin.
                    guard let id else { return }
                    let key = "box.lastUserID"
                    let previous = UserDefaults.standard.object(forKey: key) as? Int
                    // previous == nil: bu sürüm ilk kez açıldı; önceden kimin aradığı bilinmediği için bir kez temizle.
                    if previous == nil || previous != id {
                        history.clear()
                        feed.reset()
                        downloads.reset()
                    }
                    UserDefaults.standard.set(id, forKey: key)
                }
                .onChange(of: auth.token) { token in
                    guard token != nil else {
                        // Çıkış yapıldı: hesaba ait her şeyi temizle.
                        history.clear()
                        feed.reset()
                        downloads.reset()
                        library.allowsRemote = false
                        player.dropRemoteTracks()
                        return
                    }
                    // Giriş yapılınca bildirim izni bir kez sorulur, cihaz hesaba bağlanır.
                    Task {
                        await PushManager.shared.requestIfNeeded()
                        await PushManager.shared.upload()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        if auth.token != nil { Task { await PushManager.shared.requestIfNeeded() } }
                        Task {
                            await library.refresh()
                            await server.refresh()
                            await auth.refresh()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .boxShortcut)) { note in
                    guard let raw = note.object as? String, let action = BoxShortcutAction(rawValue: raw) else { return }
                    switch action {
                    case .favorites: player.play(library.favoriteTracks, startAt: 0, shuffled: true)
                    case .shuffle: player.play(library.tracks, startAt: 0, shuffled: true)
                    case .recent: player.play(library.recentlyPlayed, startAt: 0)
                    case .resume: player.resume()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background { library.flushStats() }
                }
                .onChange(of: library.tracks) { tracks in
                    player.handleLibraryChange(validPaths: Set(tracks.map(\.relativePath)))
                }
        }
    }
}

/// Sekmeler ve uygulama genelindeki sayfalar.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: BoxTab = .home
    @Published var showAccount = false
    @Published private(set) var toast: Toast?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var icon: String = "checkmark.circle.fill"
        var track: Track? = nil
    }

    private var toastTask: Task<Void, Never>?

    /// Kısa bilgi baloncuğu (ör. "Listeye eklendi").
    func show(_ text: String, icon: String = "checkmark.circle.fill", track: Track? = nil) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = Toast(text: text, icon: icon, track: track) }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.toast = nil }
        }
    }
}
