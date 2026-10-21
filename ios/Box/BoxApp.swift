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
    @StateObject private var lang = Lang.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
                // Dil değişince bütün ekranlar yeni dille yeniden çizilsin (uygulama yeniden başlamaz).
                .id(lang.code)
                .environment(\.locale, lang.locale)
                .environment(\.layoutDirection, lang.layoutDirection)
                .environmentObject(lang)
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
                        guard let stream else { throw APIError(message: L("Hazır değil."), status: 0) }
                        return try await stream.resolve(result)
                    }
                    player.liveRemote = { [weak stream] result in
                        guard let stream else { throw APIError(message: L("Hazır değil."), status: 0) }
                        return try await stream.liveURL(result)
                    }
                    player.prefetchRemote = { [weak stream] result in stream?.prepareLink(result) }
                    player.videoURLFor = { [weak stream] id in
                        guard let stream else { throw APIError(message: L("Hazır değil."), status: 0) }
                        return try await stream.videoURL(id)
                    }
                    player.videoIDFor = { [weak library] track in library?.videoID(forPath: track.relativePath) }
                    player.onStreamCached = { [weak stream] result, temp in stream?.store(result, temp: temp) }
                    player.onRemoteSeen = { [weak library] result in library?.remember(result) }
                    player.radioProvider = { [weak feed, weak auth, weak library] track, exclude in
                        guard let feed, let auth, auth.has(.radio), let library else { return [] }
                        let results = await feed.radio(for: track, exclude: exclude, token: auth.token)
                        return library.playable(results)
                    }
                    player.autoRadioEnabled = { [weak auth] in AppSettings.shared.autoRadio && auth?.has(.radio) == true }
                    player.isPlayable = { [weak stream, weak auth] track in
                        guard let remote = track.remote else { return true }
                        guard auth?.has(.stream) == true else { return false }
                        return NetworkMonitor.shared.isOnline || stream?.isCached(remote.id) == true
                    }
                    player.allowsRemote = { [weak auth] in auth?.has(.stream) == true }
                    library.allowsRemote = auth.has(.stream)
                    player.crossfade = { AppSettings.shared.crossfadeSeconds }
                    player.effects = { (AppSettings.shared.eqPreset, AppSettings.shared.normalizeVolume) }
                    player.visualizer = { AppSettings.shared.visualizer }
                    downloads.network = network
                    downloads.isAllowed = { [weak auth] in auth?.has(.download) == true }
                    downloads.onBlocked = { [weak router] in router?.show(L("İndirme hesabında kapalı."), icon: "lock.fill") }
                    player.onListen = { [weak library] track, seconds in library?.addListen(track, seconds: seconds) }
                    PremiumStore.shared.start(auth: auth)
                    PushManager.shared.tokenProvider = { [weak auth] in auth?.token }
                    PushManager.shared.onOpen = { [weak router] target in
                        switch target {
                        case "account": router?.showAccount = true
                        case "search": router?.tab = .search
                        case "library": router?.tab = .library
                        default: router?.tab = .home
                        }
                    }
                    library.syncToken = { [weak auth] in auth?.token }
                    auth.beforeLogout = { [weak library] in await library?.syncNow() }
                    auth.onAccountDeleted = { [weak library] id in library?.forgetAccount(id) }
                    await library.refresh()
                    library.activateAccount(auth.user?.id)
                    player.restoreIfNeeded(tracks: library.tracks)
                    // Kaldığı yerden devam eden sırada internet şarkısı varsa ve premium yoksa çıkar.
                    if !auth.has(.stream) { player.dropRemoteTracks() }
                    await server.refresh()
                    await auth.refresh()
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    switch url.pathExtension.lowercased() {
                    case "boxlist":
                        if let lists = SharedListFile.read(from: url), !lists.isEmpty {
                            router.importRequest = ImportRequest(lists: lists)
                        } else {
                            router.show(L("Bu dosya bir Box listesi değil."), icon: "exclamationmark.triangle.fill")
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
                .onChange(of: auth.featureState) { _ in
                    // Premium (ya da bir parçası) kapanınca ona ait hiçbir şey kalmasın: internet şarkıları,
                    // video, radyo, bekleyen indirmeler, öneriler.
                    library.allowsRemote = auth.has(.stream)
                    if !auth.has(.stream) { player.dropRemoteTracks() }
                    if !auth.has(.download) { downloads.cancelAll() }
                    if !auth.has(.search) { feed.reset() }
                    if !auth.isPremium { history.clear() }
                }
                .onChange(of: auth.user?.id) { id in
                    // Listeler ve beğeniler hesaba ait: çıkışta kaldırılır, girişte o hesabınki gelir.
                    library.activateAccount(id)
                    // Duyuru kime gösterileceğine göre sunucuda süzülür: giriş/çıkışta yeniden sor.
                    Task { await server.refresh() }
                    // Cihazda satın alma var ama bu hesapta görünmüyorsa (ör. yeniden giriş) sunucuya bildir.
                    if id != nil { Task { await PremiumStore.shared.syncIfNeeded() } }
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
                        InboxStore.shared.reset()
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
                        await InboxStore.shared.load(token: auth.token, userID: auth.user?.id)
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        if auth.token != nil {
                            Task {
                                await PushManager.shared.requestIfNeeded()
                                await InboxStore.shared.load(token: auth.token, userID: auth.user?.id)
                            }
                        }
                        Task {
                            await library.refresh()
                            await server.refresh()
                            await auth.refresh()
                            library.requestSync(immediately: true)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .boxInboxRefresh)) { _ in
                    Task { await InboxStore.shared.load(token: auth.token, userID: auth.user?.id) }
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
                .onChange(of: lang.code) { _ in
                    // Ana sayfa bölümleri ve bildirimler sunucudan yeni dille gelsin.
                    feed.reset()
                    Task { await InboxStore.shared.load(token: auth.token, userID: auth.user?.id) }
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
    /// Sanatçı / albüm sayfası (her yerden açılır, kendi gezinme yığınıyla).
    @Published var musicPage: MusicPage?
    @Published var showInbox = false
    /// Box Premium satın alma ekranı.
    @Published var showPremium = false
    /// Açılan .boxlist dosyası (içe aktarma ekranı).
    @Published var importRequest: ImportRequest?
    /// İçe aktarılan listeyi Kitaplık'ta aç.
    @Published var openPlaylist: UUID?

    /// Tam ekran oynatıcı açıksa önce kapatıp sonra sayfayı açar (iki sayfa aynı anda açılamaz).
    func openMusic(_ page: MusicPage, player: PlayerManager? = nil) {
        if let player, player.showFullPlayer {
            player.showFullPlayer = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.musicPage = page }
        } else {
            musicPage = page
        }
    }
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
