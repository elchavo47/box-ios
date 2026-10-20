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

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Yumuşak geçiş", systemImage: "waveform.path")
                        Spacer()
                        Text(settings.crossfadeSeconds == 0 ? "Kapalı" : "\(Int(settings.crossfadeSeconds)) sn")
                            .foregroundColor(.boxSecondaryText)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.crossfadeSeconds, in: 0...12, step: 1)
                        .tint(.accent)
                }
                .padding(.vertical, 4)

                Picker(selection: $settings.eqPresetRaw) {
                    ForEach(EQPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                } label: {
                    Label("Ekolayzer", systemImage: "slider.vertical.3")
                }

                Toggle(isOn: $settings.normalizeVolume) {
                    Label("Ses seviyesini eşitle", systemImage: "speaker.wave.2")
                }
                .tint(.accent)

                Toggle(isOn: $settings.visualizer) {
                    Label("Ses dalgası", systemImage: "waveform")
                }
                .tint(.accent)

                if auth.isPremium {
                    Toggle(isOn: $settings.autoRadio) {
                        Label("Sıra bitince benzerleriyle devam et", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .tint(.accent)
                }
            } header: {
                Text("Oynatma")
            } footer: {
                Text("Ekolayzer ve ses eşitleme bir sonraki şarkıdan itibaren uygulanır.")
            }
            .listRowBackground(Color.boxSurface2)

            if auth.isPremium {
                Section {
                    Toggle(isOn: $settings.wifiOnlyDownloads) {
                        Label("Sadece Wi‑Fi'da indir", systemImage: "wifi")
                    }
                    .tint(.accent)
                    Toggle(isOn: $settings.searchSuggestions) {
                        Label("Arama önerileri", systemImage: "text.magnifyingglass")
                    }
                    .tint(.accent)
                } header: {
                    Text("İndirme ve arama")
                } footer: {
                    Text("Mobil veride bekleyen indirmeler Wi‑Fi'a bağlanınca kendiliğinden başlar.")
                }
                .listRowBackground(Color.boxSurface2)
            }

            Section("Depolama ve kitaplık") {
                NavigationLink {
                    StorageView()
                } label: {
                    Label("Depolama", systemImage: "internaldrive")
                }
                NavigationLink {
                    DuplicatesView()
                } label: {
                    Label("Kopya şarkıları bul", systemImage: "doc.on.doc")
                }
                Button {
                    backupURL = BackupService.write(library.makeBackup(), name: "Box yedeği \(Self.dayString)", ext: "boxbackup")
                } label: {
                    Label("Kitaplığı yedekle", systemImage: "icloud.and.arrow.up")
                }
                Button {
                    showRestore = true
                } label: {
                    Label("Yedekten geri yükle", systemImage: "icloud.and.arrow.down")
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section("Uygulama ikonu") {
                HStack(spacing: 18) {
                    iconChoice(nil, preview: "IconPreviewDark", title: "Gece")
                    iconChoice("AppIconLight", preview: "IconPreviewLight", title: "Açık")
                    iconChoice("AppIconGreen", preview: "IconPreviewGreen", title: "Yeşil")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                Button {
                    settings.onboarded = false
                } label: {
                    Label("Tanıtımı yeniden göster", systemImage: "sparkles")
                }
            }
            .listRowBackground(Color.boxSurface2)
        }
        .scrollContentBackground(.hidden)
        .background(Color.boxSurface.ignoresSafeArea())
        .navigationTitle("Ayarlar")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { backupURL.map(ShareItem.init) }, set: { backupURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [.boxBackup, .json]) { result in
            guard case .success(let url) = result else { return }
            if let backup = BackupService.read(LibraryBackup.self, from: url), backup.kind == "box.backup" {
                let added = library.restore(backup)
                message = "Yedek geri yüklendi. \(added) yeni liste eklendi; beğeniler ve geçmiş birleştirildi."
            } else {
                message = "Bu dosya bir Box yedeği değil."
            }
        }
        .alert("Yedekleme", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Tamam", role: .cancel) {}
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

            Section("Özet") {
                row("Kitaplık", Formatters.bytes(library.totalSize), "\(library.tracks.count) şarkı", icon: "music.note")
                row("İndirilenler", Formatters.bytes(downloadsSize), "\(library.downloadedTracks.count) şarkı", icon: "arrow.down.circle")
                HStack {
                    row("Dinleme önbelleği", Formatters.bytes(cacheSize), "Kitaplıkta görünmez", icon: "icloud")
                    Button("Temizle") {
                        stream.clear()
                        cacheSize = 0
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(cacheSize == 0)
                }
            }
            .listRowBackground(Color.boxSurface2)

            Section("En çok yer kaplayan sanatçılar") {
                ForEach(topArtists, id: \.name) { item in
                    row(item.name, Formatters.bytes(item.size), "\(item.count) şarkı", icon: "music.mic")
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
                        Button(role: .destructive) { deleteTarget = track } label: { Label("Sil", systemImage: "trash") }
                    }
                }
            } header: {
                Text("En büyük dosyalar")
            } footer: {
                Text("Silmek için sola kaydır. Silinen dosya listelerden de çıkar.")
            }
            .listRowBackground(Color.boxSurface2)
        }
        .scrollContentBackground(.hidden)
        .background(Color.boxSurface.ignoresSafeArea())
        .navigationTitle("Depolama")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheSize = stream.totalSize }
        .confirmationDialog(
            deleteTarget.map { "\"\($0.title)\" silinsin mi?" } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let track = deleteTarget { delete(track) }
            }
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
                legend(.accent, "İndirilenler")
                legend(.accentDeep, "Diğer")
                legend(.white.opacity(0.35), "Önbellek")
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
                EmptyStateView(icon: "checkmark.circle", title: "Kopya yok", message: "Aynı şarkının birden fazla kopyası bulunamadı.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.first!.id) { group in
                Section {
                    ForEach(Array(group.enumerated()), id: \.element.id) { index, track in
                        HStack {
                            TrackRow(track: track, showMenu: false)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Formatters.bytes(track.fileSize)).font(.caption.monospacedDigit())
                                if index == 0 { Text("En iyi").font(.caption2.weight(.bold)).foregroundColor(.accent) }
                            }
                            .foregroundColor(.boxSecondaryText)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if player.current?.id == track.id { player.next() }
                                try? FileService.delete(track.url)
                                library.pathDeleted(track.url)
                                Task { await library.refresh() }
                            } label: { Label("Sil", systemImage: "trash") }
                        }
                    }
                } footer: {
                    Text("\(group.count) kopya • sola kaydırarak fazlasını sil")
                }
                .listRowBackground(Color.boxSurface2)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.boxSurface.ignoresSafeArea())
        .navigationTitle("Kopya şarkılar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
