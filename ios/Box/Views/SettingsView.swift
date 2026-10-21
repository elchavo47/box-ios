import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: AuthStore

    @State private var backupURL: URL?
    @State private var showRestore = false
    @State private var message: String?
    @State private var iconName: String? = UIApplication.shared.alternateIconName

    @EnvironmentObject private var lang: Lang

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LanguagePickerView()
                } label: {
                    HStack {
                        Label(L("Dil"), systemImage: "globe")
                        Spacer()
                        Text(lang.choice == "auto" ? L("Otomatik ({0})", lang.language.name) : lang.language.name)
                            .foregroundColor(.boxSecondaryText)
                    }
                }
            } footer: {
                Text(L("Otomatik seçiliyse Box telefonunun dilini kullanır; desteklenmeyen dillerde İngilizce açılır."))
            }
            .listRowBackground(Color.boxSurface2)

            if auth.isPremium {
                Section {
                    Toggle(isOn: $settings.hideBrowser) {
                        Label(L("Tarayıcı sekmesini gizle"), systemImage: "globe")
                    }
                    .tint(.accent)
                } footer: {
                    Text(L("Alt paneldeki Tarayıcı sekmesi kaldırılır; istediğin zaman geri açabilirsin."))
                }
                .listRowBackground(Color.boxSurface2)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L("Yumuşak geçiş"), systemImage: "waveform.path")
                        Spacer()
                        Text(settings.crossfadeSeconds == 0 ? L("Kapalı") : L("{0} sn", Int(settings.crossfadeSeconds)))
                            .foregroundColor(.boxSecondaryText)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.crossfadeSeconds, in: 0...12, step: 1)
                        .tint(.accent)
                }
                .padding(.vertical, 4)

                Toggle(isOn: $settings.normalizeVolume) {
                    Label(L("Ses seviyesini eşitle"), systemImage: "speaker.wave.2")
                }
                .tint(.accent)

                Toggle(isOn: $settings.visualizer) {
                    Label(L("Ses dalgası"), systemImage: "waveform")
                }
                .tint(.accent)

                if auth.has(.radio) {
                    Toggle(isOn: $settings.autoRadio) {
                        Label(L("Sıra bitince benzerleriyle devam et"), systemImage: "dot.radiowaves.left.and.right")
                    }
                    .tint(.accent)
                }
            } header: {
                Text(L("Oynatma"))
            } footer: {
                Text(L("Ekolayzer, çalan şarkı ekranındaki ekolayzer düğmesinde."))
            }
            .listRowBackground(Color.boxSurface2)

            if auth.has(.download) || auth.has(.search) {
                Section {
                    if auth.has(.download) {
                        Toggle(isOn: $settings.wifiOnlyDownloads) {
                            Label(L("Sadece Wi‑Fi'da indir"), systemImage: "wifi")
                        }
                        .tint(.accent)
                    }
                    if auth.has(.search) {
                        Toggle(isOn: $settings.searchSuggestions) {
                            Label(L("Arama önerileri"), systemImage: "text.magnifyingglass")
                        }
                        .tint(.accent)
                    }
                } header: {
                    Text(L("İndirme ve arama"))
                } footer: {
                    Text(L("Mobil veride bekleyen indirmeler Wi‑Fi'a bağlanınca kendiliğinden başlar."))
                }
                .listRowBackground(Color.boxSurface2)
            }

            Section(L("Depolama ve kitaplık")) {
                NavigationLink {
                    StorageView()
                } label: {
                    Label(L("Depolama"), systemImage: "internaldrive")
                }
                NavigationLink {
                    DuplicatesView()
                } label: {
                    Label(L("Kopya şarkıları bul"), systemImage: "doc.on.doc")
                }
                Button {
                    backupURL = BackupService.write(library.makeBackup(), name: L("Box yedeği {0}", Self.dayString), ext: "boxbackup")
                } label: {
                    Label(L("Kitaplığı yedekle"), systemImage: "icloud.and.arrow.up")
                }
                Button {
                    showRestore = true
                } label: {
                    Label(L("Yedekten geri yükle"), systemImage: "icloud.and.arrow.down")
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section(L("Uygulama ikonu")) {
                HStack(spacing: 18) {
                    iconChoice(nil, preview: "IconPreviewDark", title: L("Gece"))
                    iconChoice("AppIconLight", preview: "IconPreviewLight", title: L("Açık"))
                    iconChoice("AppIconGreen", preview: "IconPreviewGreen", title: L("Yeşil"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                Button {
                    settings.onboarded = false
                } label: {
                    Label(L("Tanıtımı yeniden göster"), systemImage: "sparkles")
                }
            }
            .listRowBackground(Color.boxSurface2)
        }
        .scrollContentBackground(.hidden)
        .background(Color.boxSurface.ignoresSafeArea())
        .navigationTitle(L("Ayarlar"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { backupURL.map(ShareItem.init) }, set: { backupURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [.boxBackup, .json]) { result in
            guard case .success(let url) = result else { return }
            if let backup = BackupService.read(LibraryBackup.self, from: url), backup.kind == "box.backup" {
                let added = library.restore(backup)
                message = L("Yedek geri yüklendi. {0} yeni liste eklendi; beğeniler ve geçmiş birleştirildi.", added)
            } else {
                message = L("Bu dosya bir Box yedeği değil.")
            }
        }
        .alert(L("Yedekleme"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("Tamam"), role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private static var dayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func iconChoice(_ name: String?, preview: String, title: String) -> some View {
        Button {
            UIApplication.shared.setAlternateIconName(name) { error in
                if error == nil { iconName = name }
            }
        } label: {
            VStack(spacing: 6) {
                Image(preview)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(iconName == name ? Color.accent : Color.clear, lineWidth: 2.5)
                            .padding(-4)
                    )
                Text(title).font(.caption).foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Depolama

struct StorageView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var stream: StreamCache
    @EnvironmentObject private var player: PlayerManager

    @State private var cacheSize: Int64 = 0
    @State private var deleteTarget: Track?

    private var downloadsSize: Int64 { library.downloadedTracks.reduce(0) { $0 + $1.fileSize } }

    var body: some View {
        List {
            Section {
                bar
                    .listRowBackground(Color.clear)
            }

            Section(L("Özet")) {
                row(L("Kitaplık"), Formatters.bytes(library.totalSize), L("{0} şarkı", library.tracks.count), icon: "music.note")
                row(L("İndirilenler"), Formatters.bytes(downloadsSize), L("{0} şarkı", library.downloadedTracks.count), icon: "arrow.down.circle")
                HStack {
                    row(L("Dinleme önbelleği"), Formatters.bytes(cacheSize), L("Kitaplıkta görünmez"), icon: "icloud")
                    Button(L("Temizle")) {
                        stream.clear()
                        cacheSize = 0
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(cacheSize == 0)
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section(L("En çok yer kaplayan sanatçılar")) {
                ForEach(topArtists, id: \.name) { item in
                    row(item.name, Formatters.bytes(item.size), L("{0} şarkı", item.count), icon: "music.mic")
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                ForEach(largest) { track in
                    HStack {
                        TrackRow(track: track, showMenu: false)
                        Text(Formatters.bytes(track.fileSize))
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.boxSecondaryText)
                    }
                    .swipeActions {
                        Button(role: .destructive) { deleteTarget = track } label: { Label(L("Sil"), systemImage: "trash") }
                    }
                }
            } header: {
                Text(L("En büyük dosyalar"))
            } footer: {
                Text(L("Silmek için sola kaydır. Silinen dosya listelerden de çıkar."))
            }
            .listRowBackground(Color.boxSurface2)
        }
        .scrollContentBackground(.hidden)
        .background(Color.boxSurface.ignoresSafeArea())
        .navigationTitle(L("Depolama"))
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheSize = stream.totalSize }
        .boxConfirm(
            deleteTarget.map { L("\"{0}\" silinsin mi?", $0.title) } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            icon: "trash",
            confirmTitle: L("Sil")
        ) {
            if let track = deleteTarget { delete(track) }
        }
    }

    private var bar: some View {
        let total = max(library.totalSize + cacheSize, 1)
        let other = library.totalSize - downloadsSize
        return VStack(alignment: .leading, spacing: 10) {
            Text(Formatters.bytes(library.totalSize + cacheSize))
                .font(.system(size: 30, weight: .bold))
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.accent).frame(width: proxy.size.width * CGFloat(downloadsSize) / CGFloat(total))
                    Rectangle().fill(Color.accentDeep).frame(width: proxy.size.width * CGFloat(max(other, 0)) / CGFloat(total))
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: proxy.size.width * CGFloat(cacheSize) / CGFloat(total))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .background(Capsule().fill(Color.white.opacity(0.08)))
            HStack(spacing: 14) {
                legend(.accent, L("İndirilenler"))
                legend(.accentDeep, L("Diğer"))
                legend(.white.opacity(0.35), L("Önbellek"))
            }
            .font(.caption)
            .foregroundColor(.boxSecondaryText)
        }
        .padding(.vertical, 6)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 8, height: 8); Text(text) }
    }

    private func row(_ title: String, _ value: String, _ sub: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(sub).font(.caption).foregroundColor(.boxSecondaryText)
            }
            Spacer()
            Text(value).foregroundColor(.boxSecondaryText).monospacedDigit()
        }
    }

    private var topArtists: [(name: String, size: Int64, count: Int)] {
        library.artists
            .map { (name: $0.name, size: $0.tracks.reduce(Int64(0)) { $0 + $1.fileSize }, count: $0.tracks.count) }
            .sorted { $0.size > $1.size }
            .prefix(6)
            .map { $0 }
    }

    private var largest: [Track] {
        Array(library.tracks.sorted { $0.fileSize > $1.fileSize }.prefix(20))
    }

    private func delete(_ track: Track) {
        if player.current?.id == track.id { player.next() }
        try? FileService.delete(track.url)
        library.pathDeleted(track.url)
        Task { await library.refresh() }
        deleteTarget = nil
    }
}

// MARK: - Kopya şarkılar

struct DuplicatesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    private var groups: [[Track]] {
        let normalized = Dictionary(grouping: library.tracks) { track in
            (LyricsService.cleanTitle(track.title) + "|" + LyricsService.cleanArtist(track.displayArtist))
                .lowercased()
                .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
                .filter { $0.isLetter || $0.isNumber || $0 == "|" }
        }
        return normalized.values
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.fileSize > $1.fileSize } }
            .sorted { $0[0].title < $1[0].title }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                EmptyStateView(icon: "checkmark.circle", title: L("Kopya yok"), message: L("Aynı şarkının birden fazla kopyası bulunamadı."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.first!.id) { group in
                Section {
                    ForEach(Array(group.enumerated()), id: \.element.id) { index, track in
                        HStack {
                            TrackRow(track: track, showMenu: false)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Formatters.bytes(track.fileSize)).font(.caption.monospacedDigit())
                                if index == 0 { Text(L("En iyi")).font(.caption2.weight(.bold)).foregroundColor(.accent) }
                            }
                            .foregroundColor(.boxSecondaryText)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if player.current?.id == track.id { player.next() }
                                try? FileService.delete(track.url)
                                library.pathDeleted(track.url)
                                Task { await library.refresh() }
                            } label: { Label(L("Sil"), systemImage: "trash") }
                        }
                    }
                } footer: {
                    Text(L("{0} kopya • sola kaydırarak fazlasını sil", group.count))
                }
                .listRowBackground(Color.boxSurface2)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.boxSurface.ignoresSafeArea())
        .navigationTitle(L("Kopya şarkılar"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
