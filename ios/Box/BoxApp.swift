import SwiftUI

@main
struct BoxApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerManager()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var history = SearchHistory()
    @StateObject private var server = ServerState()
    @StateObject private var router = AppRouter()
    @StateObject private var stream = StreamCache()
    @StateObject private var feed = FeedStore()
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
                    await library.refresh()
                    player.restoreIfNeeded(tracks: library.tracks)
                    await server.refresh()
                    await auth.refresh()
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task {
                        let inbox = library.documents.appendingPathComponent(AppConfig.inboxFolderName, isDirectory: true)
                        await library.importFiles([url], into: inbox)
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task {
                            await library.refresh()
                            await server.refresh()
                            await auth.refresh()
                        }
                    }
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
}
