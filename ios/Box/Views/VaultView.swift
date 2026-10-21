import SwiftUI

/// Dosyalar sekmesinin en üstündeki "Kilitli klasör" satırı.
struct VaultEntryRow: View {
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var vault = VaultStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vault.isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accent))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L("Kilitli klasör"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    if !auth.has(.vault) {
                        Text("PREMIUM")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accent))
                    }
                }
                Text(L("{0} ile açılır, Dosyalar uygulamasında görünmez", vault.biometryName))
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// Kilitli klasörün kendisi: kilitliyken kilit ekranı, açıkken dosyalar.
struct VaultView: View {
    var folder: URL? = nil

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var vault = VaultStore.shared

    @State private var items: [FileItem] = []
    @State private var tracks: [Track] = []
    @State private var showPremium = false
    @State private var failed = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var deleteTarget: FileItem?
    @State private var errorMessage: String?
    @State private var autoPrompted = false

    private var isRoot: Bool { folder == nil }

    var body: some View {
        Group {
            if !auth.has(.vault) {
                locked(premium: true)
            } else if !vault.isUnlocked {
                locked(premium: false)
            } else {
                content
            }
        }
        .boxScreenBackground()
        .navigationTitle(isRoot ? L("Kilitli klasör") : (folder?.lastPathComponent ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if vault.isUnlocked && auth.has(.vault) {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !tracks.isEmpty {
                        Button { player.play(tracks, startAt: 0, shuffled: true) } label: { Image(systemName: "shuffle") }
                            .accessibilityLabel(L("Karıştır"))
                    }
                    Menu {
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: {
                            Label(L("Yeni klasör"), systemImage: "folder.badge.plus")
                        }
                        Button {
                            vault.lock()
                        } label: {
                            Label(L("Şimdi kilitle"), systemImage: "lock.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task(id: vault.isUnlocked) {
            // Açılışta bir kez Face ID sorulur; "Şimdi kilitle"den sonra yeniden sorulmaz.
            if isRoot, !autoPrompted, auth.has(.vault), !vault.isUnlocked, vault.canLock {
                autoPrompted = true
                await attemptUnlock()
            }
            await reload()
        }
        .onChange(of: vault.revision) { _ in Task { await reload() } }
        .sheet(isPresented: $showPremium) { PremiumView() }
        .alert(L("Yeni klasör"), isPresented: $showNewFolder) {
            TextField(L("Klasör adı"), text: $newFolderName)
            Button(L("Oluştur")) { perform { try vault.createFolder(named: newFolderName, in: folder) } }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .alert(L("Yeniden adlandır"), isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField(L("Yeni ad"), text: $renameText)
            Button(L("Kaydet")) {
                guard let target = renameTarget else { return }
                perform { try vault.rename(target.url, to: renameText) }
            }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .boxConfirm(
            deleteTarget.map { L("\"{0}\" silinsin mi?", $0.name) } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            icon: "trash",
            message: L("Kilitli klasörden silinen dosyalar geri getirilemez."),
            confirmTitle: L("Sil")
        ) {
            guard let target = deleteTarget else { return }
            perform {
                stopIfPlaying(target)
                try vault.delete(target.url)
            }
        }
        .alert(L("İşlem yapılamadı"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L("Tamam"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Kilit ekranı

    private func locked(premium: Bool) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: premium ? "lock.fill" : vault.biometryIcon)
                .font(.system(size: 46, weight: .regular))
                .foregroundColor(.accent)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Color.accentSoft))
            Text(L("Kilitli klasör"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            Text(premium
                 ? (auth.isPremium ? L("Kilitli klasör hesabında kapalı.") : L("Özel şarkılarını ve dosyalarını {0} ile açılan, Dosyalar uygulamasında görünmeyen bir klasörde sakla. Box Premium ile açılır.", vault.biometryName))
                 : (vault.canLock ? L("Açmak için {0} kullan.", vault.biometryName) : L("Kilitli klasörü kullanmak için iPhone'unda bir parola ayarla.")))
                .font(.system(size: 15))
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if failed && !premium {
                Text(L("Kilit açılamadı."))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.orange)
            }
            if premium {
                if !auth.isPremium {
                    Button { showPremium = true } label: { Text(L("Premium'a geç")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.horizontal, 40)
                }
            } else if vault.canLock {
                Button { Task { await attemptUnlock() } } label: {
                    Label(L("Kilidi aç"), systemImage: vault.biometryIcon)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: İçerik

    private var content: some View {
        List {
            if items.isEmpty {
                EmptyStateView(
                    icon: "lock.shield",
                    title: L("Kilitli klasör boş"),
                    message: L("Dosyalar sekmesinde bir şarkıya ya da klasöre basılı tut, \"Kilitli klasöre taşı\"yı seç.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                row(item)
                    .listRowBackground(Color.clear)
                    .contextMenu { menu(item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deleteTarget = item } label: { Label(L("Sil"), systemImage: "trash") }
                        Button { moveOut(item) } label: { Label(L("Çıkar"), systemImage: "lock.open") }.tint(.gray)
                    }
            }
            if isRoot && !items.isEmpty {
                Text(L("Buradaki şarkılar kitaplıkta, geçmişte ve istatistiklerde görünmez. Uygulamadan çıkınca klasör yeniden kilitlenir."))
                    .font(.footnote)
                    .foregroundColor(.boxSecondaryText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ item: FileItem) -> some View {
        if item.isDirectory {
            NavigationLink {
                VaultView(folder: item.url)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accent)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.boxSurface2))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                        Text(L("{0} öğe", item.childCount)).font(.subheadline).foregroundColor(.boxSecondaryText)
                    }
                }
            }
        } else if let track = tracks.first(where: { $0.url == item.url }) {
            TrackRow(track: track, showMenu: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    let index = tracks.firstIndex(of: track) ?? 0
                    player.play(tracks, startAt: index)
                }
        } else {
            HStack(spacing: 12) {
                Image(systemName: item.isAudio ? "music.note" : "doc.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.boxSecondaryText)
                    .frame(width: 50, height: 50)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.boxSurface2))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 16)).lineLimit(1)
                    Text(Formatters.bytes(item.size)).font(.subheadline).foregroundColor(.boxSecondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ item: FileItem) -> some View {
        if let track = tracks.first(where: { $0.url == item.url }) {
            Button { player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0) } label: { Label(L("Çal"), systemImage: "play.fill") }
            Button { player.addToQueue(track) } label: { Label(L("Sıraya ekle"), systemImage: "text.append") }
        }
        Button {
            renameText = item.isDirectory ? item.name : (item.name as NSString).deletingPathExtension
            renameTarget = item
        } label: { Label(L("Yeniden adlandır"), systemImage: "pencil") }
        Button { moveOut(item) } label: { Label(L("Kilitli klasörden çıkar"), systemImage: "lock.open") }
        Button(role: .destructive) { deleteTarget = item } label: { Label(L("Sil"), systemImage: "trash") }
    }

    // MARK: İşlemler

    private func attemptUnlock() async {
        failed = false
        let ok = await vault.unlock()
        failed = !ok
        if ok { Haptics.success() }
    }

    private func reload() async {
        guard vault.isUnlocked, auth.has(.vault) else {
            items = []
            tracks = []
            return
        }
        let list = vault.list(folder)
        items = list
        tracks = await vault.tracks(in: list)
    }

    /// Box ana klasörüne çıkarır; kitaplığa geri girer.
    private func moveOut(_ item: FileItem) {
        perform {
            stopIfPlaying(item)
            try vault.moveOut(item.url, to: library.documents)
            await library.refresh()
        }
    }

    private func stopIfPlaying(_ item: FileItem) {
        guard let current = player.current?.url.standardizedFileURL.path else { return }
        let path = item.url.standardizedFileURL.path
        if current == path || (item.isDirectory && current.hasPrefix(path + "/")) { player.stop() }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
