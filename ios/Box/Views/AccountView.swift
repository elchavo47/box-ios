import AuthenticationServices
import PhotosUI
import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if auth.isLoggedIn, let user = auth.user {
                    ProfileView(user: user)
                } else {
                    AuthFormView()
                }
            }
            .background(Color.boxSurface.ignoresSafeArea())
            .navigationTitle(L("Hesap"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("Ayarlar"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Bitti")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Giriş / kayıt

private struct AuthFormView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var server: ServerState

    @State private var isRegister = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var appleRequest = AppleSignInRequest()
    @FocusState private var focused: Field?

    enum Field { case name, email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= (isRegister ? 8 : 1) && !auth.isWorking
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BoxMark(size: 64)
                    .padding(.top, 24)

                VStack(spacing: 6) {
                    Text(isRegister ? L("Box'a katıl") : L("Tekrar hoş geldin"))
                        .font(.system(size: 26, weight: .bold))
                    Text(isRegister && !server.registrationOpen ? L("Yeni kayıtlar şu an kapalı.") : L("Premium ayrıcalıkların hesabına bağlı kalsın."))
                        .font(.subheadline)
                        .foregroundColor(.boxSecondaryText)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    Button(L("Giriş yap")) { withAnimation { isRegister = false } }
                        .buttonStyle(ChipButtonStyle(selected: !isRegister))
                    Button(L("Kayıt ol")) { withAnimation { isRegister = true } }
                        .buttonStyle(ChipButtonStyle(selected: isRegister))
                }

                VStack(spacing: 12) {
                    if isRegister {
                        field(L("İsim"), text: $name, icon: "person")
                            .textContentType(.name)
                            .focused($focused, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focused = .email }
                    }

                    field(L("E-posta"), text: $email, icon: "envelope")
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }

                    secureField(L("Şifre") + (isRegister ? L(" (en az 8 karakter)") : ""), text: $password)
                        .textContentType(isRegister ? .newPassword : .password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit()
                } label: {
                    if auth.isWorking {
                        ProgressView().tint(.black)
                    } else {
                        Text(isRegister ? L("Hesap oluştur") : L("Giriş yap"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)

                HStack(spacing: 12) {
                    Rectangle().fill(Color.boxStroke).frame(height: 1)
                    Text(L("veya")).font(.footnote).foregroundColor(.boxSecondaryText)
                    Rectangle().fill(Color.boxStroke).frame(height: 1)
                }

                // Apple ile giriş: hesap yoksa kendiliğinden açılır, ayrıca kayıt gerekmez.
                SignInWithAppleButton(.continue) { request in
                    let fresh = AppleSignInRequest()
                    appleRequest = fresh
                    fresh.configure(request)
                } onCompletion: { outcome in
                    appleCompleted(outcome)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 48)
                .clipShape(Capsule())
                .disabled(auth.isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func field(_ placeholder: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.boxSecondaryText)
                .frame(width: 20)
            TextField(placeholder, text: text)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.boxSurface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.boxStroke))
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .foregroundColor(.boxSecondaryText)
                .frame(width: 20)
            SecureField(placeholder, text: text)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.boxSurface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.boxStroke))
    }

    private func appleCompleted(_ outcome: Result<ASAuthorization, Error>) {
        errorMessage = nil
        do {
            guard let result = try appleRequest.result(from: outcome) else { return }
            Task {
                do {
                    try await auth.signInWithApple(result)
                    Haptics.success()
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Apple ile giriş yapılamadı.")
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Apple ile giriş yapılamadı.")
        }
    }

    private func submit() {
        errorMessage = nil
        focused = nil

        Task {
            do {
                if isRegister {
                    try await auth.register(name: name, email: email, password: password)
                } else {
                    try await auth.login(email: email, password: password)
                }
                password = ""
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Bir hata oluştu.")
            }
        }
    }
}

// MARK: - Profil

/// Sayarak artan sayı (istatistik kutuları).
private struct CountUpText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))").monospacedDigit()
    }
}

/// Bölümlerin sırayla, aşağıdan süzülerek gelmesi.
private struct Rise: ViewModifier {
    let shown: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(Double(index) * 0.07), value: shown)
    }
}

/// Üstteki yavaşça hareket eden ışık bulutu.
private struct ProfileAurora: View {
    let premium: Bool
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accent.opacity(premium ? 0.42 : 0.24))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: drift ? -70 : 60, y: drift ? -40 : 10)
            Circle()
                .fill(Color(red: 0.25, green: 0.75, blue: 0.95).opacity(premium ? 0.26 : 0.14))
                .frame(width: 260, height: 260)
                .blur(radius: 100)
                .offset(x: drift ? 90 : -50, y: drift ? 30 : -30)
            Circle()
                .fill(Color.accentDeep.opacity(0.5))
                .frame(width: 220, height: 220)
                .blur(radius: 90)
                .offset(x: drift ? 10 : -30, y: drift ? 90 : 60)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// Kartın üzerinden ara ara geçen ışık.
private struct Shimmer: ViewModifier {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Color.white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.5)
                    .rotationEffect(.degrees(18))
                    .offset(x: phase ? proxy.size.width * 1.3 : -proxy.size.width * 0.8)
            }
            .allowsHitTesting(false)
        )
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).delay(0.8).repeatForever(autoreverses: false)) { phase = true }
        }
    }
}

/// Cam görünümlü kart zemini.
private struct GlassCard: ViewModifier {
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

private extension View {
    func glassCard(radius: CGFloat = 22) -> some View { modifier(GlassCard(radius: radius)) }
    func rise(_ shown: Bool, _ index: Int) -> some View { modifier(Rise(shown: shown, index: index)) }
}

/// Menü satırı: renkli simge kutusu, başlık ve sağda değer.
private struct ProfileRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var showsChevron = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.16)))
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.boxTertiaryText)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 61)
    }
}

private struct ProfileView: View {
    let user: BoxUser

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var stream: StreamCache
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showRename = false
    @State private var cacheSize: Int64 = 0
    @State private var newName = ""
    @State private var showLogoutConfirm = false
    @State private var showDelete = false
    @State private var deletePassword = ""
    @State private var errorMessage: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var cropping: CropItem?
    @State private var appleRequest = AppleSignInRequest()
    @State private var showUnlink = false
    @State private var showPremium = false
    @State private var appeared = false
    @State private var spin = false
    @State private var pulse = false
    @State private var insight = Insight()
    @ObservedObject private var push = PushManager.shared

    private struct CropItem: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    /// Dinleme özeti (toplam dinleme, en çok dinlenen şarkı ve sanatçı).
    private struct Insight {
        var plays = 0
        var topTrack: Track?
        var topArtist: String?
        var artistPlays = 0
    }

    private func computeInsight() {
        var result = Insight()
        var artists: [String: Int] = [:]
        var best = 0
        for (path, count) in library.playCounts where count > 0 {
            result.plays += count
            guard let track = library.track(forPath: path) else { continue }
            if count > best { best = count; result.topTrack = track }
            if !track.artist.isEmpty { artists[track.artist, default: 0] += count }
        }
        if let top = artists.max(by: { $0.value < $1.value }) {
            result.topArtist = top.key
            result.artistPlays = top.value
        }
        insight = result
    }

    private var notificationsOn: Bool { push.status == .authorized || push.status == .provisional }

    private func linkApple(_ outcome: Result<ASAuthorization, Error>) {
        do {
            guard let result = try appleRequest.result(from: outcome) else { return }
            Task {
                do {
                    try await auth.linkApple(result)
                    Haptics.success()
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Apple bağlanamadı.")
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Apple bağlanamadı.")
        }
    }

    private func upload(_ image: UIImage) {
        Task {
            uploading = true
            defer { uploading = false }
            do {
                try await auth.uploadAvatar(image)
                Haptics.success()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Fotoğraf yüklenemedi.")
            }
        }
    }

    private var syncFooter: String {
        if case .failed(let message) = library.syncStatus { return message + L(" Değişikliklerin bu cihazda saklanıyor, bağlantı gelince gönderilir.") }
        if let date = library.syncState.lastSync {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            f.locale = Lang.shared.locale
            return L("Listelerin ve beğenilerin hesabına kayıtlı; çıkış yapıp başka cihazdan girince de gelir. Son eşitleme: {0}.", f.localizedString(for: date, relativeTo: Date()))
        }
        return L("Listelerin ve beğenilerin hesabına kaydedilir; çıkış yapıp başka cihazdan girince de gelir.")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero.rise(appeared, 0)
                statsStrip.rise(appeared, 1)
                if insight.plays > 0 { insightCard.rise(appeared, 2) }
                premiumCard.rise(appeared, 3)
                generalGroup.rise(appeared, 4)
                accountGroup.rise(appeared, 5)
                if let error = player.lastStreamError, user.premium {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle(L("Son akış hatası"))
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.boxSecondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .glassCard(radius: 16)
                    }
                }
                dangerGroup.rise(appeared, 6)
                VStack(spacing: 4) {
                    BoxWordmark(markSize: 18)
                    Text(L("Sürüm {0} • AYD Works", AppConfig.appVersion))
                        .font(.caption2)
                        .foregroundColor(.boxSecondaryText)
                }
                .padding(.top, 6)
                .padding(.bottom, 28)
                .rise(appeared, 7)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(alignment: .top) { ProfileAurora(premium: user.premium).ignoresSafeArea(edges: .top) }
        .onAppear {
            computeInsight()
            appeared = true
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                uploading = true
                defer { uploading = false; photoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    errorMessage = L("Fotoğraf açılamadı.")
                    return
                }
                // Büyük fotoğrafı belleği yormadan küçült, sonra ayarlama ekranını aç.
                let image = await Task.detached(priority: .userInitiated) { ImageDownsampler.image(from: data, maxPixel: 2048) }.value
                guard let image else {
                    errorMessage = L("Fotoğraf açılamadı.")
                    return
                }
                cropping = CropItem(image: image)
            }
        }
        .fullScreenCover(item: $cropping) { item in
            AvatarCropView(image: item.image, onCancel: { cropping = nil }) { result in
                cropping = nil
                upload(result)
            }
        }
        .refreshable { await auth.refresh() }
        .task { cacheSize = stream.totalSize }
        .task { await push.refreshStatus() }
        .sheet(isPresented: $showPremium) {
            PremiumView().presentationDragIndicator(.visible)
        }
        .alert(L("İsmini değiştir"), isPresented: $showRename) {
            TextField(L("İsim"), text: $newName)
            Button(L("Kaydet")) {
                Task {
                    do {
                        try await auth.updateName(newName.trimmingCharacters(in: .whitespaces))
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                    }
                }
            }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .boxConfirm(
            L("Çıkış yapılsın mı?"),
            isPresented: $showLogoutConfirm,
            icon: "rectangle.portrait.and.arrow.right",
            message: L("Listelerin ve beğenilerin hesabına kayıtlı; tekrar girince geri gelir."),
            confirmTitle: L("Çıkış yap")
        ) {
            Task { await auth.logout() }
        }
        .boxConfirm(
            L("Apple bağlantısı kaldırılsın mı?"),
            isPresented: $showUnlink,
            icon: "apple.logo",
            message: L("Sonra yalnızca e-posta ve şifrenle giriş yaparsın."),
            confirmTitle: L("Kaldır")
        ) {
            Task {
                do { try await auth.unlinkApple() } catch { errorMessage = (error as? LocalizedError)?.errorDescription }
            }
        }
        .alert(L("Hesabı sil"), isPresented: $showDelete) {
            if user.hasPassword != false {
                SecureField(L("Şifren"), text: $deletePassword)
            }
            Button(L("Kalıcı olarak sil"), role: .destructive) {
                Task {
                    do {
                        try await auth.deleteAccount(password: deletePassword)
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                    }
                }
            }
            Button(L("Vazgeç"), role: .cancel) {}
        } message: {
            Text(L("Hesabın ve sunucudaki bilgilerin silinir. Cihazındaki müzik dosyaları silinmez."))
        }
        .alert(L("Hata"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L("Tamam"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundColor(.boxSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.boxTertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
    }

    // MARK: - Üst bölüm

    private var avatarRing: some View {
        ZStack {
            // Dışa doğru yayılan nabız halkası (premium)
            if user.premium {
                Circle()
                    .stroke(Color.accent.opacity(pulse ? 0 : 0.45), lineWidth: 2)
                    .frame(width: 128, height: 128)
                    .scaleEffect(pulse ? 1.22 : 1)
            }
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: user.premium
                            ? [Color.accent, Color(red: 0.45, green: 0.95, blue: 0.85), Color(red: 0.25, green: 0.7, blue: 1), Color.accent]
                            : [Color.white.opacity(0.35), Color.white.opacity(0.06), Color.white.opacity(0.35)],
                        center: .center
                    ),
                    lineWidth: 3.5
                )
                .frame(width: 124, height: 124)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .shadow(color: Color.accent.opacity(user.premium ? 0.55 : 0), radius: 18)
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        avatarRing
                        UserAvatar(user: user, size: 108)
                            .overlay {
                                if uploading {
                                    ZStack {
                                        Circle().fill(Color.black.opacity(0.45))
                                        ProgressView().tint(.white)
                                    }
                                }
                            }
                    }
                    .frame(width: 132, height: 132)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().stroke(Color.boxSurface, lineWidth: 3))
                        .offset(x: -6, y: -6)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(L("Profil fotoğrafını değiştir"))
            .contextMenu {
                if user.avatarURL != nil {
                    Button(role: .destructive) {
                        Task {
                            do { try await auth.removeAvatar() } catch { errorMessage = (error as? LocalizedError)?.errorDescription }
                        }
                    } label: {
                        Label(L("Profil fotoğrafını kaldır"), systemImage: "person.crop.circle.badge.minus")
                    }
                }
            }

            VStack(spacing: 5) {
                Text(user.name)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(user.email)
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
            }
            planBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var statsStrip: some View {
        HStack(spacing: 10) {
            statTile(library.tracks.count, L("Şarkı"), icon: "music.note")
            statTile(library.playlists.count, L("Liste"), icon: "music.note.list")
            statTile(library.favorites.count, L("Beğeni"), icon: "heart.fill")
        }
    }

    private func statTile(_ value: Int, _ title: String, icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accent.opacity(0.14)))
            CountUpText(value: appeared ? Double(value) : 0)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .animation(.easeOut(duration: 1.1).delay(0.25), value: appeared)
            Text(title)
                .font(.caption)
                .foregroundColor(.boxSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassCard(radius: 20)
    }

    // MARK: - Dinleme özeti

    private var insightCard: some View {
        NavigationLink {
            HomeRouteView(route: .summary)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L("Senin müziğin"), systemImage: "waveform")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.boxTertiaryText)
                }
                HStack(alignment: .center, spacing: 14) {
                    if let track = insight.topTrack {
                        ArtworkView(url: track.url, size: 62, cornerRadius: 12, fallback: track.artworkFallback)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            CountUpText(value: appeared ? Double(insight.plays) : 0)
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .animation(.easeOut(duration: 1.3).delay(0.35), value: appeared)
                            Text(L("dinleme"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.boxSecondaryText)
                        }
                        if let track = insight.topTrack {
                            Text(L("En çok: {0}", track.title))
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        if let artist = insight.topArtist {
                            Text(L("Favori sanatçı: {0}", artist))
                                .font(.system(size: 13))
                                .foregroundColor(.boxSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .glassCard()
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }

    // MARK: - Premium

    @ViewBuilder
    private var premiumCard: some View {
        Button { showPremium = true } label: {
            if user.premium {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(LinearGradient(colors: [Color.accent, Color(red: 0.45, green: 0.95, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .shadow(color: Color.accent.opacity(0.5), radius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Box Premium").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(.white)
                            Text(premiumRowSubtitle).font(.caption).foregroundColor(.boxSecondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundColor(.boxTertiaryText)
                    }
                    if let quota = auth.quota {
                        HStack(spacing: 12) {
                            usageRing(L("İndirme"), used: quota.downloadsUsed, limit: quota.downloadsLimit, icon: "arrow.down")
                            usageRing(L("Arama"), used: quota.searchesUsed, limit: quota.searchesLimit, icon: "magnifyingglass")
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [Color.accent.opacity(0.20), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.accent.opacity(0.75), Color.accent.opacity(0.08), Color(red: 0.25, green: 0.7, blue: 1).opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                )
                .modifier(Shimmer())
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Premium'a geç")).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(.black)
                        Text(premiumRowSubtitle).font(.caption).foregroundColor(.black.opacity(0.7)).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.12)))
                }
                .padding(16)
                .background(
                    LinearGradient(colors: [Color.accent, Color(red: 0.45, green: 0.95, blue: 0.85), Color.accentMid], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .modifier(Shimmer())
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.accent.opacity(0.35), radius: 18, y: 8)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }

    private func usageRing(_ title: String, used: Int, limit: Int, icon: String) -> some View {
        let fraction = limit > 0 ? min(1, Double(used) / Double(max(limit, 1))) : 0
        let full = limit > 0 && used >= limit
        return HStack(spacing: 11) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: appeared ? fraction : 0)
                    .stroke(full ? Color.orange : Color.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 1.1).delay(0.5), value: appeared)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(full ? .orange : .accent)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(limit > 0 ? "\(used) / \(limit)" : "\(used)")
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                Text(title).font(.caption).foregroundColor(.boxSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.22)))
    }

    // MARK: - Menüler

    private var generalGroup: some View {
        VStack(spacing: 8) {
            sectionTitle(L("Genel"))
            VStack(spacing: 0) {
                NavigationLink { SettingsView() } label: {
                    ProfileRow(icon: "gearshape.fill", tint: Color(white: 0.75), title: L("Ayarlar")) { EmptyView() }
                }
                RowDivider()
                Button {
                    switch push.status {
                    case .notDetermined: Task { await push.requestIfNeeded() }
                    default: push.openSettings()
                    }
                } label: {
                    ProfileRow(icon: "bell.fill", tint: Color(red: 1, green: 0.42, blue: 0.42), title: L("Bildirimler")) {
                        Text(notificationsOn ? L("Açık") : push.status == .notDetermined ? L("Aç") : L("Kapalı"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(notificationsOn ? .accent : .boxSecondaryText)
                    }
                }
                RowDivider()
                NavigationLink { StorageView() } label: {
                    ProfileRow(icon: "internaldrive.fill", tint: Color(red: 0.4, green: 0.7, blue: 1), title: L("Depolama")) {
                        Text(Formatters.bytes(library.totalSize + cacheSize))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.boxSecondaryText)
                    }
                }
                RowDivider()
                Button { library.requestSync(immediately: true) } label: {
                    ProfileRow(icon: "arrow.triangle.2.circlepath", tint: .accent, title: L("Hesaba kaydet"), showsChevron: false) {
                        switch library.syncStatus {
                        case .syncing: ProgressView().tint(.white)
                        case .failed: Image(systemName: "exclamationmark.icloud.fill").foregroundColor(.orange)
                        case .idle: Image(systemName: "checkmark.icloud.fill").foregroundColor(.accent)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .glassCard()
            footnote(syncFooter)
        }
    }

    private var accountGroup: some View {
        VStack(spacing: 8) {
            sectionTitle(L("Hesap ve güvenlik"))
            VStack(spacing: 0) {
                Button {
                    newName = user.name
                    showRename = true
                } label: {
                    ProfileRow(icon: "pencil", tint: Color(red: 1, green: 0.75, blue: 0.3), title: L("İsmi değiştir")) { EmptyView() }
                }
                RowDivider()
                NavigationLink { DevicesView() } label: {
                    ProfileRow(icon: "iphone.gen3", tint: Color(red: 0.7, green: 0.55, blue: 1), title: L("Cihazlarım")) { EmptyView() }
                }
                RowDivider()
                if user.appleLinked == true {
                    ProfileRow(icon: "apple.logo", tint: .white, title: L("Apple ile giriş"), showsChevron: false) {
                        Text(L("Bağlı")).font(.system(size: 14, weight: .medium)).foregroundColor(.accent)
                    }
                    if user.hasPassword != false {
                        RowDivider()
                        Button { showUnlink = true } label: {
                            ProfileRow(icon: "link", tint: .red, title: L("Apple bağlantısını kaldır"), showsChevron: false) { EmptyView() }
                        }
                    }
                } else {
                    SignInWithAppleButton(.continue) { request in
                        let fresh = AppleSignInRequest()
                        appleRequest = fresh
                        fresh.configure(request)
                    } onCompletion: { outcome in
                        linkApple(outcome)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 46)
                    .clipShape(Capsule())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .buttonStyle(.plain)
            .glassCard()
            footnote(user.appleLinked == true
                     ? (user.hasPassword == false ? L("Bu hesap Apple ile açıldı.") : L("E-posta ve şifrenle ya da Apple ile giriş yapabilirsin."))
                     : L("Apple'ı bağlarsan bir dahaki sefere şifre yazmadan girersin."))
        }
    }

    private var dangerGroup: some View {
        VStack(spacing: 0) {
            Button { showLogoutConfirm = true } label: {
                ProfileRow(icon: "rectangle.portrait.and.arrow.right", tint: Color(white: 0.8), title: L("Çıkış yap"), showsChevron: false) { EmptyView() }
            }
            RowDivider()
            Button {
                deletePassword = ""
                showDelete = true
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.16)))
                    Text(L("Hesabı sil"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .glassCard()
    }

    @ViewBuilder
    private var planBadge: some View {
        if user.premium {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                Text(premiumText)
            }
            .font(.system(size: 12, weight: .heavy))
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(LinearGradient(colors: [Color.accent, Color(red: 0.45, green: 0.95, blue: 0.85)], startPoint: .leading, endPoint: .trailing))
            .modifier(Shimmer())
            .clipShape(Capsule())
            .shadow(color: Color.accent.opacity(0.45), radius: 10, y: 3)
        } else {
            Text(L("Ücretsiz plan"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.boxSecondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        }
    }

    private var premiumRowSubtitle: String {
        if let info = user.store {
            if info.lifetime { return L("App Store · ömür boyu") }
            if let date = info.expiresDate { return L("App Store · yenilenme {0}", date.formatted(date: .abbreviated, time: .omitted)) }
            return L("App Store")
        }
        if user.premium { return L("Hesabında açık") }
        return L("Tarayıcıdan dosya indirme ve yeni özellikler")
    }

    private var premiumText: String {
        guard let until = user.premiumUntilDate ?? (user.store?.lifetime == true ? nil : user.store?.expiresDate) else { return L("PREMIUM") }
        let formatter = DateFormatter()
        formatter.locale = Lang.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return L("PREMIUM • {0}", formatter.string(from: until))
    }
}
