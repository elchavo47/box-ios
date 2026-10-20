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
    @State private var visited: Set<BoxTab> = [.home]

    @ViewBuilder
    private func tabPage<Content: View>(_ tab: BoxTab, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(tab) {
            let active = router.tab == tab
            content()
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .accessibilityHidden(!active)
                .zIndex(active ? 1 : 0)
        }
    }

    var body: some View {
        ZStack {
            // Sistem sekme çubuğu yerine Box'un kendi alt paneli (BoxDeck).
            // Sekmeler bir kez açıldıktan sonra canlı tutulur; gezinme durumu kaybolmaz.
            ZStack {
                tabPage(.home) { HomeView() }
                tabPage(.search) { SearchView() }
                tabPage(.library) { LibraryView() }
                tabPage(.files) { FilesView() }
            }
            .overlay(alignment: .bottom) {
                BoxDeck()
                    .ignoresSafeArea(.keyboard)
            }
            .onAppear { visited.insert(router.tab) }
            .onChange(of: router.tab) { tab in visited.insert(tab) }
            .sheet(isPresented: $player.showFullPlayer) {
                FullPlayerView()
                    .presentationDragIndicator(.hidden)
                    .interactiveDismissDisabled(false)
            }
            .sheet(isPresented: $router.showAccount) {
                AccountView()
            }
            .sheet(item: $router.musicPage) { page in
                MusicBrowser(root: page)
            }
            .sheet(isPresented: $router.showInbox) {
                InboxView()
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
        .onChange(of: server.updateRequired) { required in
            // Güncelleme ekranı açık sayfaların (oynatıcı, profil) altında kalmasın.
            guard required else { return }
            player.showFullPlayer = false
            router.showAccount = false
            player.pause()
        }
        .task {
            // Uygulama açıkken de minimum sürümü dakikada bir kontrol et.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await server.refresh()
            }
        }
    }
}

/// Alt panel ölçüleri (ekranların son satırı panelin altında kalmasın diye).
enum DeckMetrics {
    static let tabs: CGFloat = 58
    static let mini: CGFloat = 62
    static let banner: CGFloat = 38
}

/// Box'un alt paneli: mini oynatıcı ve sekmeler tek parça, üstü yuvarlak koyu bir kutu.
/// Seçili sekmenin üstündeki yeşil çizgi logodaki küpün üst yüzünden geliyor ve sekmeler arasında kayar.
struct BoxDeck: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var server: ServerState
    @EnvironmentObject private var downloads: DownloadManager
    @Namespace private var lid
    @State private var keyboardShown = false

    private struct Item: Identifiable {
        let tab: BoxTab
        let title: String
        let icon: String
        let selectedIcon: String
        var id: BoxTab { tab }
    }

    private let items: [Item] = [
        Item(tab: .home, title: "Ana Sayfa", icon: "house", selectedIcon: "house.fill"),
        Item(tab: .search, title: "Ara", icon: "magnifyingglass", selectedIcon: "magnifyingglass"),
        Item(tab: .library, title: "Kitaplık", icon: "square.stack", selectedIcon: "square.stack.fill"),
        Item(tab: .files, title: "Dosyalar", icon: "folder", selectedIcon: "folder.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let message = server.maintenanceMessage {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(message).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.footnote.weight(.medium))
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .frame(height: DeckMetrics.banner)
                .background(Color(red: 0.96, green: 0.71, blue: 0.28))
            }

            if player.current != nil {
                MiniPlayerBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
            }

            HStack(spacing: 0) {
                ForEach(items) { item in
                    tabButton(item)
                }
            }
            .frame(height: DeckMetrics.tabs)
            .padding(.horizontal, 8)
        }
        .clipShape(TopRounded(radius: 22))
        .background(
            // Panel ana ekranın alt çizgisine kadar iner; köşeler yalnızca üstte yuvarlak.
            TopRounded(radius: 22)
                .fill(Color(red: 0.035, green: 0.037, blue: 0.045))
                .overlay(TopRounded(radius: 22).stroke(Color.white.opacity(0.07), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.55), radius: 18, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
        // Klavye açıkken panel gizlenir (klavyenin üstüne çıkmasın).
        .opacity(keyboardShown ? 0 : 1)
        .allowsHitTesting(!keyboardShown)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) { keyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardShown = false }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.current != nil)
        .animation(.easeOut(duration: 0.25), value: server.maintenanceMessage)
    }

    private func tabButton(_ item: Item) -> some View {
        let selected = router.tab == item.tab
        return Button {
            guard router.tab != item.tab else { return }
            Haptics.tap()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { router.tab = item.tab }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if selected {
                        Capsule()
                            .fill(Color.accent)
                            .frame(width: 22, height: 3)
                            .matchedGeometryEffect(id: "lid", in: lid)
                    } else {
                        Color.clear.frame(width: 22, height: 3)
                    }
                }
                .padding(.bottom, 3)

                ZStack(alignment: .topTrailing) {
                    Image(systemName: selected ? item.selectedIcon : item.icon)
                        .font(.system(size: 20, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .accent : Color(white: 0.6))
                        .scaleEffect(selected ? 1.06 : 1)
                        .frame(height: 22)
                    if item.tab == .search && downloads.activeCount > 0 {
                        Text("\(downloads.activeCount)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.accent))
                            .offset(x: 12, y: -6)
                    }
                }

                Text(item.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? .white : Color(white: 0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Yalnızca üst köşeleri yuvarlatılmış dikdörtgen (iOS 16 uyumlu).
struct TopRounded: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
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
