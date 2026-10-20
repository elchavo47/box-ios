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
    @EnvironmentObject private var settings: AppSettings

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
            .sheet(isPresented: $player.showFullPlayer) {
                FullPlayerView()
                    .presentationDragIndicator(.hidden)
                    .interactiveDismissDisabled(false)
            }
            .sheet(isPresented: $router.showAccount) {
                AccountView()
            }


            Color.clear
                .alert("Şarkı açılamadı", isPresented: Binding(
                    get: { player.errorMessage != nil && !player.showFullPlayer },
                    set: { if !$0 { player.errorMessage = nil } }
                )) {
                    Button("Sonrakine geç") { player.errorMessage = nil; player.next() }
                    Button("Tamam", role: .cancel) { player.errorMessage = nil }
                } message: {
                    Text(player.errorMessage ?? "")
                }
                .allowsHitTesting(false)

            if let toast = router.toast {
                VStack {
                    ToastView(toast: toast)
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(4)
                .allowsHitTesting(false)
            }

            if let announcement = server.announcement, !showSplash {
                AnnouncementCard(announcement: announcement) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { server.dismissAnnouncement() }
                }
                .zIndex(1)
                .transition(.opacity)
            }

            if !settings.onboarded && !showSplash {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(2)
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
                    UserAvatar(user: user, size: 32)
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


/// Box tasarımında, ekranın ortasında açılan duyuru kartı.
private struct AnnouncementCard: View {
    let announcement: RemoteConfig.Announcement
    let onClose: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.6 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    BoxMark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BOX DUYURU")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.accent)
                        Text(announcement.title)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                ScrollView {
                    Text(announcement.body)
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.78))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: close) {
                    Text("Tamam")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 400)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.boxSurface)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [Color.accent.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            )
            .padding(.horizontal, 24)
            .scaleEffect(shown ? 1 : 0.88)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            Haptics.soft()
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { shown = true }
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.18)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onClose() }
    }
}
