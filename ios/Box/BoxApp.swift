import SwiftUI

@main
struct BoxApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerManager()
    @StateObject private var downloads = DownloadManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.055, alpha: 0.96)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
                .tint(.neon)
                .task {
                    downloads.attach(library: library, auth: auth)
                    await library.refresh()
                    await auth.refresh()
                }
                .onOpenURL { url in
                    Task {
                        let inbox = library.documents.appendingPathComponent(AppConfig.inboxFolderName, isDirectory: true)
                        await library.importFiles([url], into: inbox)
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task {
                            await library.refresh()
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
