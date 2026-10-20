import SwiftUI

enum BoxTab: Hashable {
    case home, search, library, files
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var server: ServerState
    @EnvironmentObject private var router: AppRouter

    @State private var showSplash = true

    var body: some View {
        ZStack {
            TabView(selection: $router.tab) {
                HomeView()
                    .withMiniPlayer()
                    .tabItem { Label("Ana Sayfa", systemImage: "house.fill") }
                    .tag(BoxTab.home)

                SearchView()
                    .withMiniPlayer()
                    .tabItem { Label("Ara", systemImage: "magnifyingglass") }
                    .tag(BoxTab.search)
                    .badge(downloads.activeCount)

                LibraryView()
                    .withMiniPlayer()
                    .tabItem { Label("Kitaplık", systemImage: "square.stack.fill") }
                    .tag(BoxTab.library)

                FilesView()
                    .withMiniPlayer()
                    .tabItem { Label("Dosyalar", systemImage: "folder.fill") }
                    .tag(BoxTab.files)
            }
            .fullScreenCover(isPresented: $player.showFullPlayer) {
                FullPlayerView()
            }
            .sheet(isPresented: $router.showAccount) {
                AccountView()
            }
            .alert(
                server.announcement?.title ?? "",
                isPresented: Binding(get: { server.announcement != nil && !showSplash }, set: { if !$0 { server.dismissAnnouncement() } })
            ) {
                Button("Tamam", role: .cancel) { server.dismissAnnouncement() }
            } message: {
                Text(server.announcement?.body ?? "")
            }

            if server.updateRequired {
                UpdateRequiredView()
                    .transition(.opacity)
                    .zIndex(2)
            }

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
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
    @EnvironmentObject private var server: ServerState

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let message = server.maintenanceMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                        Text(message).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(red: 0.96, green: 0.71, blue: 0.28))
                }
                if player.current != nil {
                    MiniPlayerBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

/// Her sekmenin sağ üstündeki profil düğmesi.
struct AccountButton: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button {
            router.showAccount = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let user = auth.user {
                    Text(String(user.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.accentDeep))
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                if auth.isPremium {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.black)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.accent))
                        .overlay(Circle().stroke(Color.boxBackground, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
        }
        .accessibilityLabel("Hesap")
    }
}

private struct UpdateRequiredView: View {
    var body: some View {
        ZStack {
            Color.boxBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                BoxMark(size: 72)
                Text("Yeni sürüm hazır")
                    .font(.title2.weight(.bold))
                Text("Box'u kullanmaya devam etmek için uygulamayı TestFlight'tan güncelle.")
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    if let url = URL(string: "itms-beta://") { UIApplication.shared.open(url) }
                } label: {
                    Text("TestFlight'ı aç")
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 220)
                .padding(.top, 6)
            }
        }
    }
}
