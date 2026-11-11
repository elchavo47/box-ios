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

private struct ProfileView: View {
    let user: BoxUser

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var stream: StreamCache
    @EnvironmentObject private var player: PlayerManager

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
    @ObservedObject private var push = PushManager.shared

    private struct CropItem: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    @ViewBuilder
    private var notificationsRow: some View {
        Button {
            switch push.status {
            case .notDetermined: Task { await push.requestIfNeeded() }
            default: push.openSettings()
            }
        } label: {
            HStack {
                Label(L("Bildirimler"), systemImage: "bell")
                    .foregroundColor(.white)
                Spacer()
                Text(push.status == .authorized || push.status == .provisional ? L("Açık") : push.status == .notDetermined ? L("Aç") : L("Kapalı"))
                    .foregroundColor(push.status == .authorized || push.status == .provisional ? .accent : .boxSecondaryText)
            }
        }
        .task { await push.refreshStatus() }
    }

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
        List {
            hero
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

            statsStrip
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))

            premiumCard
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label(L("Ayarlar"), systemImage: "gearshape")
                }
                notificationsRow
                NavigationLink {
                    StorageView()
                } label: {
                    HStack {
                        Label(L("Depolama"), systemImage: "internaldrive")
                        Spacer()
                        Text(Formatters.bytes(library.totalSize + cacheSize)).foregroundColor(.boxSecondaryText)
                    }
                }
                Button {
                    library.requestSync(immediately: true)
                } label: {
                    HStack {
                        Label(L("Hesaba kaydet"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        Spacer()
                        switch library.syncStatus {
                        case .syncing: ProgressView().tint(.white)
                        case .failed: Image(systemName: "exclamationmark.icloud").foregroundColor(.orange)
                        case .idle: Image(systemName: "checkmark.icloud").foregroundColor(.accent)
                        }
                    }
                }
            } header: {
                Text(L("Genel"))
            } footer: {
                Text(syncFooter)
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                Button {
                    newName = user.name
                    showRename = true
                } label: {
                    Label(L("İsmi değiştir"), systemImage: "pencil")
                }
                NavigationLink {
                    DevicesView()
                } label: {
                    Label(L("Cihazlarım"), systemImage: "iphone.gen3")
                }
                if user.appleLinked == true {
                    HStack {
                        Label(L("Apple ile giriş"), systemImage: "apple.logo")
                        Spacer()
                        Text(L("Bağlı")).foregroundColor(.accent)
                    }
                    if user.hasPassword != false {
                        Button(role: .destructive) { showUnlink = true } label: {
                            Label(L("Apple bağlantısını kaldır"), systemImage: "link.badge.plus")
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
                    .frame(height: 44)
                    .clipShape(Capsule())
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            } header: {
                Text(L("Hesap ve güvenlik"))
            } footer: {
                Text(user.appleLinked == true
                     ? (user.hasPassword == false ? L("Bu hesap Apple ile açıldı.") : L("E-posta ve şifrenle ya da Apple ile giriş yapabilirsin."))
                     : L("Apple'ı bağlarsan bir dahaki sefere şifre yazmadan girersin."))
            }
            .listRowBackground(Color.boxSurface2)

            if let error = player.lastStreamError, user.premium {
                Section(L("Son akış hatası")) {
                    Text(error).font(.caption).foregroundColor(.boxSecondaryText).textSelection(.enabled)
                }
                .listRowBackground(Color.boxSurface2)
            }

            Section {
                Button {
                    showLogoutConfirm = true
                } label: {
                    Label(L("Çıkış yap"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) {
                    deletePassword = ""
                    showDelete = true
                } label: {
                    Label(L("Hesabı sil"), systemImage: "trash")
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        BoxWordmark(markSize: 18)
                        Text(L("Sürüm {0} • AYD Works", AppConfig.appVersion))
                            .font(.caption2)
                            .foregroundColor(.boxSecondaryText)
                    }
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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

    // MARK: - Üst bölüm

    private var hero: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    UserAvatar(user: user, size: 96)
                        .overlay {
                            if uploading { ProgressView().tint(.white) }
                        }
                        .overlay(
                            Circle()
                                .stroke(user.premium ? Color.accent : Color.boxStroke, lineWidth: 2.5)
                                .padding(-4)
                        )
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().stroke(Color.boxSurface, lineWidth: 3))
                }
            }
            .buttonStyle(.plain)
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

            VStack(spacing: 4) {
                Text(user.name)
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(user.email)
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
            }
            planBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(
            RadialGradient(colors: [Color.accent.opacity(user.premium ? 0.28 : 0.14), Color.clear], center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 230)
        )
    }

    private var statsStrip: some View {
        HStack(spacing: 10) {
            statTile("\(library.tracks.count)", L("Şarkı"), icon: "music.note")
            statTile("\(library.playlists.count)", L("Liste"), icon: "music.note.list")
            statTile("\(library.favorites.count)", L("Beğeni"), icon: "heart.fill")
        }
    }

    private func statTile(_ value: String, _ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.accent)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundColor(.boxSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.boxSurface2))
    }

    @ViewBuilder
    private var premiumCard: some View {
        Button { showPremium = true } label: {
            if user.premium {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accent))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Box Premium").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                            Text(premiumRowSubtitle).font(.caption).foregroundColor(.boxSecondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(.boxTertiaryText)
                    }
                    if let quota = auth.quota {
                        VStack(spacing: 10) {
                            usageBar(L("İndirme"), used: quota.downloadsUsed, limit: quota.downloadsLimit)
                            usageBar(L("Arama"), used: quota.searchesUsed, limit: quota.searchesLimit)
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.boxSurface2))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.black)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Premium'a geç")).font(.system(size: 17, weight: .bold)).foregroundColor(.black)
                        Text(premiumRowSubtitle).font(.caption).foregroundColor(.black.opacity(0.7)).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(.black.opacity(0.6))
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [Color.accent, Color.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            }
        }
        .buttonStyle(.plain)
    }

    private func usageBar(_ title: String, used: Int, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.footnote).foregroundColor(.boxSecondaryText)
                Spacer()
                Text(limit > 0 ? "\(used) / \(limit)" : "\(used)")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.white)
            }
            if limit > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(used >= limit ? Color.orange : Color.accent)
                            .frame(width: proxy.size.width * min(1, CGFloat(used) / CGFloat(max(limit, 1))))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    @ViewBuilder
    private var planBadge: some View {
        if user.premium {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                Text(premiumText)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accent))
        } else {
            Text(L("Ücretsiz plan"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.boxSecondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.boxCardHighlight))
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

    private func stat(_ title: String, _ value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundColor(.boxSecondaryText)
                
        }
    }
}
