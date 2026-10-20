import SwiftUI

enum BoxTab: Hashable {
    case library, files, discover, account
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager

    @State private var selection: BoxTab = .library
    @State private var showSplash = true

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                LibraryView()
                    .withMiniPlayer()
                    .tabItem { Label("Kitaplık", systemImage: "square.stack.fill") }
                    .tag(BoxTab.library)

                FilesView()
                    .withMiniPlayer()
                    .tabItem { Label("Dosyalar", systemImage: "folder.fill") }
                    .tag(BoxTab.files)

                if auth.isPremium {
                    DiscoverView()
                        .withMiniPlayer()
                        .tabItem { Label("Keşfet", systemImage: "magnifyingglass") }
                        .tag(BoxTab.discover)
                        .badge(downloads.activeCount)
                }

                AccountView()
                    .withMiniPlayer()
                    .tabItem { Label("Hesap", systemImage: "person.crop.circle") }
                    .tag(BoxTab.account)
            }
            .sheet(isPresented: $player.showFullPlayer) {
                FullPlayerView()
            }
            .onChange(of: auth.isPremium) { premium in
                if !premium && selection == .discover {
                    selection = .library
                }
            }

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.45)) {
                showSplash = false
            }
        }
    }
}

extension View {
    /// Her sekmenin altına, sekme çubuğunun hemen üstüne mini player ekler.
    func withMiniPlayer() -> some View {
        modifier(MiniPlayerInset())
    }
}

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: PlayerManager

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayerBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
