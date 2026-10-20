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
            .navigationTitle("Hesap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Ayarlar")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { dismiss() }
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
                    Text(isRegister ? "Box'a katıl" : "Tekrar hoş geldin")
                        .font(.system(size: 26, weight: .bold))
                    Text(isRegister && !server.registrationOpen ? "Yeni kayıtlar şu an kapalı." : "Premium ayrıcalıkların hesabına bağlı kalsın.")
                        .font(.subheadline)
                        .foregroundColor(.boxSecondaryText)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    Button("Giriş yap") { withAnimation { isRegister = false } }
                        .buttonStyle(ChipButtonStyle(selected: !isRegister))
                    Button("Kayıt ol") { withAnimation { isRegister = true } }
                        .buttonStyle(ChipButtonStyle(selected: isRegister))
                }

                VStack(spacing: 12) {
                    if isRegister {
                        field("İsim", text: $name, icon: "person")
                            .textContentType(.name)
                            .focused($focused, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focused = .email }
                    }

                    field("E-posta", text: $email, icon: "envelope")
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }

                    secureField("Şifre" + (isRegister ? " (en az 8 karakter)" : ""), text: $password)
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
                        Text(isRegister ? "Hesap oluştur" : "Giriş yap")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)

                HStack(spacing: 12) {
                    Rectangle().fill(Color.boxStroke).frame(height: 1)
                    Text("veya").font(.footnote).foregroundColor(.boxSecondaryText)
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
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "Apple ile giriş yapılamadı."
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Apple ile giriş yapılamadı."
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
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bir hata oluştu."
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
                Label("Bildirimler", systemImage: "bell")
                    .foregroundColor(.white)
                Spacer()
                Text(push.status == .authorized || push.status == .provisional ? "Açık" : push.status == .notDetermined ? "Aç" : "Kapalı")
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
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "Apple bağlanamadı."
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Apple bağlanamadı."
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
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Fotoğraf yüklenemedi."
            }
        }
    }

    private var syncFooter: String {
        if case .failed(let message) = library.syncStatus { return message + " Değişikliklerin bu cihazda saklanıyor, bağlantı gelince gönderilir." }
        if let date = library.syncState.lastSync {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return "Listelerin ve beğenilerin hesabına kayıtlı; çıkış yapıp başka cihazdan girince de gelir. Son eşitleme: \(f.localizedString(for: date, relativeTo: Date()))."
        }
        return "Listelerin ve beğenilerin hesabına kaydedilir; çıkış yapıp başka cihazdan girince de gelir."
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            UserAvatar(user: user, size: 68)
                                .overlay {
                                    if uploading { ProgressView().tint(.white) }
                                }
                            Image(systemName: "camera.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white))
                                .overlay(Circle().stroke(Color.boxSurface2, lineWidth: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profil fotoğrafını değiştir")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.system(size: 20, weight: .bold))
                        Text(user.email)
                            .font(.subheadline)
                            .foregroundColor(.boxSecondaryText)
                        planBadge
                    }
                }
                .padding(.vertical, 6)

                if user.avatarURL != nil {
                    Button(role: .destructive) {
                        Task {
                            do { try await auth.removeAvatar() } catch { errorMessage = (error as? LocalizedError)?.errorDescription }
                        }
                    } label: {
                        Label("Profil fotoğrafını kaldır", systemImage: "person.crop.circle.badge.minus")
                    }
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Ayarlar", systemImage: "gearshape")
                }
                notificationsRow
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                if user.appleLinked == true {
                    HStack {
                        Label("Apple ile giriş", systemImage: "apple.logo")
                        Spacer()
                        Text("Bağlı").foregroundColor(.accent)
                    }
                    if user.hasPassword != false {
                        Button(role: .destructive) { showUnlink = true } label: {
                            Label("Apple bağlantısını kaldır", systemImage: "link.badge.plus")
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
                Text("Giriş yöntemi")
            } footer: {
                Text(user.appleLinked == true
                     ? (user.hasPassword == false ? "Bu hesap Apple ile açıldı." : "E-posta ve şifrenle ya da Apple ile giriş yapabilirsin.")
                     : "Bağlarsan bir dahaki sefere şifre yazmadan Apple ile girersin.")
            }
            .listRowBackground(Color.boxSurface2)

            if user.premium, let quota = auth.quota {
                Section("Bugünkü kullanım") {
                    stat("İndirme", quota.downloadsLimit > 0 ? "\(quota.downloadsUsed) / \(quota.downloadsLimit)" : "\(quota.downloadsUsed)", icon: "arrow.down.circle")
                    stat("Arama", quota.searchesLimit > 0 ? "\(quota.searchesUsed) / \(quota.searchesLimit)" : "\(quota.searchesUsed)", icon: "magnifyingglass")
                }
                .listRowBackground(Color.boxSurface2)
            }

            Section {
                stat("Şarkı", "\(library.tracks.count)", icon: "music.note")
                stat("Çalma listesi", "\(library.playlists.count)", icon: "music.note.list")
                stat("Beğenilen", "\(library.favorites.count)", icon: "heart.fill")
                stat("Kullanılan alan", Formatters.bytes(library.totalSize), icon: "internaldrive")
                Button {
                    library.requestSync(immediately: true)
                } label: {
                    HStack {
                        Label("Hesaba kaydet", systemImage: "arrow.triangle.2.circlepath.icloud")
                        Spacer()
                        switch library.syncStatus {
                        case .syncing: ProgressView().tint(.white)
                        case .failed: Image(systemName: "exclamationmark.icloud").foregroundColor(.orange)
                        case .idle: Image(systemName: "checkmark.icloud").foregroundColor(.accent)
                        }
                    }
                }
            } header: {
                Text("Kitaplığın")
            } footer: {
                Text(syncFooter)
            }
            .listRowBackground(Color.boxSurface2)

            if user.premium {
                Section {
                    HStack {
                        Label("Dinleme önbelleği", systemImage: "icloud.and.arrow.down")
                        Spacer()
                        Text(Formatters.bytes(cacheSize)).foregroundColor(.boxSecondaryText)
                    }
                    Button {
                        stream.clear()
                        cacheSize = 0
                    } label: {
                        Label("Önbelleği temizle", systemImage: "trash")
                    }
                    .disabled(cacheSize == 0)
                    if let error = player.lastStreamError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Son akış hatası").font(.footnote.weight(.semibold))
                            Text(error).font(.caption).foregroundColor(.boxSecondaryText).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("İndirmeden dinlediğin şarkılar tekrar beklememen için burada tutulur, kitaplıkta görünmez. Yer azalınca en eskileri kendiliğinden silinir.")
                }
                .listRowBackground(Color.boxSurface2)
            }

            Section("Hesap") {
                Button {
                    newName = user.name
                    showRename = true
                } label: {
                    Label("İsmi değiştir", systemImage: "pencil")
                }

                NavigationLink {
                    DevicesView()
                } label: {
                    Label("Cihazlarım", systemImage: "iphone.gen3")
                }

                Button {
                    showLogoutConfirm = true
                } label: {
                    Label("Çıkış yap", systemImage: "rectangle.portrait.and.arrow.right")
                }

                Button(role: .destructive) {
                    deletePassword = ""
                    showDelete = true
                } label: {
                    Label("Hesabı sil", systemImage: "trash")
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        BoxWordmark(markSize: 18)
                        Text("Sürüm \(AppConfig.appVersion) • AYD Works")
                            .font(.caption2)
                            .foregroundColor(.boxSecondaryText)
                    }
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                uploading = true
                defer { uploading = false; photoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    errorMessage = "Fotoğraf açılamadı."
                    return
                }
                // Büyük fotoğrafı belleği yormadan küçült, sonra ayarlama ekranını aç.
                let image = await Task.detached(priority: .userInitiated) { ImageDownsampler.image(from: data, maxPixel: 2048) }.value
                guard let image else {
                    errorMessage = "Fotoğraf açılamadı."
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
        .alert("İsmini değiştir", isPresented: $showRename) {
            TextField("İsim", text: $newName)
            Button("Kaydet") {
                Task {
                    do {
                        try await auth.updateName(newName.trimmingCharacters(in: .whitespaces))
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                    }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .confirmationDialog("Çıkış yapılsın mı?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Çıkış yap", role: .destructive) {
                Task { await auth.logout() }
            }
        }
        .confirmationDialog("Apple bağlantısı kaldırılsın mı?", isPresented: $showUnlink, titleVisibility: .visible) {
            Button("Kaldır", role: .destructive) {
                Task {
                    do { try await auth.unlinkApple() } catch { errorMessage = (error as? LocalizedError)?.errorDescription }
                }
            }
        } message: {
            Text("Sonra yalnızca e-posta ve şifrenle giriş yaparsın.")
        }
        .alert("Hesabı sil", isPresented: $showDelete) {
            if user.hasPassword != false {
                SecureField("Şifren", text: $deletePassword)
            }
            Button("Kalıcı olarak sil", role: .destructive) {
                Task {
                    do {
                        try await auth.deleteAccount(password: deletePassword)
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                    }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Hesabın ve sunucudaki bilgilerin silinir. Cihazındaki müzik dosyaları silinmez.")
        }
        .alert("Hata", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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
            Text("Ücretsiz plan")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.boxSecondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.boxCardHighlight))
        }
    }

    private var premiumText: String {
        guard let until = user.premiumUntilDate else { return "PREMIUM" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM yyyy"
        return "PREMIUM • \(formatter.string(from: until))"
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
