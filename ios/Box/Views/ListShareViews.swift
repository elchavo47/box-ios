import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dışa aktarma

/// Dışa aktarılabilecek listeler: kendi listelerin, beğenilenler ve otomatik listeler.
enum ExportItem: Hashable, Identifiable {
    case favorites
    case playlist(UUID)
    case recent
    case downloads
    case smart(SmartList)

    var id: String {
        switch self {
        case .favorites: return "favorites"
        case .playlist(let id): return id.uuidString
        case .recent: return "recent"
        case .downloads: return "downloads"
        case .smart(let list): return "smart-" + list.rawValue
        }
    }
}

/// .boxlist dosyası (Dosyalar'a kaydetmek için).
struct BoxListDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.boxPlaylist] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ExportRow: Identifiable {
    let item: ExportItem
    let name: String
    let count: Int
    var id: String { item.id }
}

struct ListExportView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<ExportItem>
    @State private var shareURL: URL?
    @State private var exportDocument: BoxListDocument?
    @State private var showExporter = false
    @State private var savedMessage: String?

    init(preselected: Set<ExportItem> = []) {
        _selected = State(initialValue: preselected)
    }

    private var available: [ExportRow] {
        var items: [ExportRow] = []
        let favorites = library.favoriteTracks.count
        if favorites > 0 { items.append(ExportRow(item: .favorites, name: L("Beğenilenler"), count: favorites)) }
        for playlist in library.playlists {
            items.append(ExportRow(item: .playlist(playlist.id), name: playlist.name, count: library.tracks(for: playlist).count))
        }
        return items
    }

    private var automatic: [ExportRow] {
        var items: [ExportRow] = []
        if !library.recentlyPlayed.isEmpty { items.append(ExportRow(item: .recent, name: L("Son çalınanlar"), count: library.recentlyPlayed.count)) }
        if !library.downloadedTracks.isEmpty { items.append(ExportRow(item: .downloads, name: L("İndirilenler"), count: library.downloadedTracks.count)) }
        for list in SmartList.allCases {
            let count = tracks(for: .smart(list)).count
            if count > 0 { items.append(ExportRow(item: .smart(list), name: list.title, count: count)) }
        }
        return items
    }

    private func tracks(for item: ExportItem) -> [Track] {
        switch item {
        case .favorites: return library.favoriteTracks
        case .playlist(let id): return library.playlist(id).map { library.tracks(for: $0) } ?? []
        case .recent: return library.recentlyPlayed
        case .downloads: return library.downloadedTracks
        case .smart(.mostPlayed): return library.mostPlayed
        case .smart(.forgotten): return library.forgotten
        case .smart(.thisMonth): return library.addedThisMonth
        }
    }

    /// Seçilenler, ekrandaki sırayla.
    private var lists: [SharedPlaylist] {
        (available + automatic).filter { selected.contains($0.item) }.map { library.shared(tracks(for: $0.item), name: $0.name) }
    }

    private var localCount: Int { lists.reduce(0) { $0 + ($1.locals?.count ?? 0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(available) { item in row(item) }
                } header: { Text(L("Listelerin")) }
                if !automatic.isEmpty {
                    Section {
                        ForEach(automatic) { item in row(item) }
                    } header: { Text(L("Otomatik listeler")) }
                }
                Section {
                    Label {
                        Text(localCount > 0
                             ? L("{0} şarkı kendi dosyan: adı ve sanatçısıyla eklenir. Dosyası olan cihazda otomatik eşleşir, olmayanda YouTube Music'te aranabilir.", localCount)
                             : L("Şarkılar adı, sanatçısı ve YouTube kimliğiyle eklenir; müzik dosyaları dosyaya girmez."))
                    } icon: { Image(systemName: "info.circle") }
                    .font(.footnote)
                    .foregroundColor(.boxSecondaryText)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .navigationTitle(L("Dışa aktar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L("Kapat")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    let all = Set((available + automatic).map(\.item))
                    Button(selected == all ? L("Hiçbiri") : L("Tümü")) {
                        selected = selected == all ? [] : all
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button {
                        shareURL = SharedListFile.write(lists)
                    } label: { Label(L("Paylaş"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle())
                    Button {
                        if let data = SharedListFile.data(for: lists) {
                            exportDocument = BoxListDocument(data: data)
                            showExporter = true
                        }
                    } label: { Label(L("Dosyalara kaydet"), systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
                }
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.boxBackground.opacity(0.96).ignoresSafeArea())
            }
            .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url]).presentationDetents([.medium, .large])
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .boxPlaylist, defaultFilename: SharedListFile.fileName(for: lists)) { result in
                if case .success = result {
                    Haptics.success()
                    savedMessage = selected.count == 1 ? L("Liste dosyası kaydedildi.") : L("{0} liste tek dosyada kaydedildi.", selected.count)
                }
            }
            .alert(L("Kaydedildi"), isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
                Button(L("Tamam"), role: .cancel) { dismiss() }
            } message: { Text(savedMessage ?? "") }
        }
    }

    private func row(_ row: ExportRow) -> some View {
        Button {
            if selected.contains(row.item) { selected.remove(row.item) } else { selected.insert(row.item) }
            Haptics.tap()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(row.item) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected.contains(row.item) ? .accent : .boxSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).foregroundColor(.white).lineLimit(1)
                    Text(L("{0} şarkı", row.count)).font(.caption).foregroundColor(.boxSecondaryText)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.06))
    }
}

// MARK: - İçe aktarma

/// .boxlist açıldığında: listeleri ve eşleşmeleri gösterir, onaylanınca kitaplığa ekler.
struct ImportRequest: Identifiable {
    let id = UUID()
    let lists: [SharedPlaylist]
}

private struct MatchResponse: Decodable {
    let results: [SearchResult?]
}

struct ListImportView: View {
    let request: ImportRequest
    var onImported: (Playlist?) -> Void = { _ in }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<Int>
    @State private var searchMissing = true
    @State private var working = false
    @State private var progress: Double = 0
    @State private var resultMessage: String?
    @State private var lastImported: Playlist?

    init(request: ImportRequest, onImported: @escaping (Playlist?) -> Void = { _ in }) {
        self.request = request
        self.onImported = onImported
        _selected = State(initialValue: Set(request.lists.indices))
    }

    private struct Summary {
        let paths: [String]
        let missing: [SharedLocal]
    }

    private var summaries: [Summary] {
        request.lists.map { list in
            let match = library.matchLocals(list.locals ?? [])
            return Summary(paths: match.paths, missing: match.missing)
        }
    }

    private var missingTotal: Int {
        let s = summaries
        return selected.reduce(0) { $0 + s[$1].missing.count }
    }

    var body: some View {
        NavigationStack {
            let s = summaries
            List {
                Section {
                    ForEach(request.lists.indices, id: \.self) { index in
                        let list = request.lists[index]
                        Button {
                            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                        } label: {
                            HStack(spacing: 12) {
                                if request.lists.count > 1 {
                                    Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundColor(selected.contains(index) ? .accent : .boxSecondaryText)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(list.name).foregroundColor(.white).lineLimit(1)
                                    Text(detail(list, s[index]))
                                        .font(.caption)
                                        .foregroundColor(.boxSecondaryText)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(request.lists.count == 1 || working)
                        .listRowBackground(Color.white.opacity(0.06))
                    }
                } header: {
                    Text(request.lists.count == 1 ? L("Liste") : L("{0} liste", request.lists.count))
                }

                if missingTotal > 0 {
                    Section {
                        if auth.has(.match) {
                            Toggle(isOn: $searchMissing) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Bulunamayanları YouTube Music'te ara"))
                                    Text(L("{0} şarkı bu cihazda yok; bulunanlar internetten çalar.", missingTotal))
                                        .font(.caption).foregroundColor(.boxSecondaryText)
                                }
                            }
                            .tint(.accent)
                            .disabled(working)
                        } else {
                            Label(L("{0} şarkı bu cihazda yok ve eklenemeyecek. Premium ile YouTube Music'te aranıp eklenebilir.", missingTotal), systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundColor(.boxSecondaryText)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.06))
                }

                if working {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Şarkılar aranıyor…")).font(.subheadline)
                            ProgressView(value: progress).tint(.accent)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.06))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .navigationTitle(L("Listeyi içe aktar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Vazgeç")) { dismiss() }.disabled(working)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await runImport() }
                } label: {
                    if working { ProgressView().tint(.black) } else { Label(selected.count > 1 ? L("{0} listeyi içe aktar", selected.count) : L("İçe aktar"), systemImage: "square.and.arrow.down") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected.isEmpty || working)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.boxBackground.opacity(0.96).ignoresSafeArea())
            }
            .alert(L("İçe aktarıldı"), isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button(L("Tamam"), role: .cancel) {
                    dismiss()
                    onImported(lastImported)
                }
            } message: { Text(resultMessage ?? "") }
        }
        .interactiveDismissDisabled(working)
    }

    private func detail(_ list: SharedPlaylist, _ summary: Summary) -> String {
        var parts = [L("{0} şarkı", list.count)]
        if !list.items.isEmpty { parts.append(L("{0} internetten", list.items.count)) }
        if let locals = list.locals, !locals.isEmpty {
            parts.append(summary.missing.isEmpty ? L("{0} dosya bu cihazda bulundu", locals.count) : L("{0}/{1} dosya bu cihazda", summary.paths.count, locals.count))
        }
        return parts.joined(separator: " • ")
    }

    private func runImport() async {
        working = true
        defer { working = false }
        let s = summaries
        let indices = request.lists.indices.filter { selected.contains($0) }
        var found: [Int: [SearchResult]] = [:]
        var notFound = 0

        if auth.has(.match), searchMissing, let token = auth.token {
            let jobs = indices.flatMap { index in s[index].missing.map { (index, $0) } }
            var done = 0
            for chunk in stride(from: 0, to: jobs.count, by: 25).map({ Array(jobs[$0..<min($0 + 25, jobs.count)]) }) {
                let body: [String: Any] = ["items": chunk.map { ["title": $0.1.title, "artist": $0.1.artist, "duration": $0.1.duration] as [String: Any] }]
                if let response: MatchResponse = try? await APIClient.shared.send("match", method: "POST", body: body, token: token) {
                    for (offset, job) in chunk.enumerated() {
                        if offset < response.results.count, let result = response.results[offset] {
                            found[job.0, default: []].append(result)
                        } else {
                            notFound += 1
                        }
                    }
                } else {
                    notFound += chunk.count
                }
                done += chunk.count
                progress = Double(done) / Double(max(jobs.count, 1))
            }
        } else {
            notFound = indices.reduce(0) { $0 + s[$1].missing.count }
        }

        var imported: [Playlist] = []
        for index in indices {
            imported.append(library.importShared(request.lists[index], localPaths: s[index].paths, extra: found[index] ?? []))
        }
        Haptics.success()
        lastImported = imported.count == 1 ? imported.first : nil
        let names = imported.count == 1 ? L("\"{0}\" kitaplığına eklendi.", imported[0].name) : L("{0} liste kitaplığına eklendi.", imported.count)
        resultMessage = notFound > 0 ? names + L(" {0} şarkı bulunamadığı için eklenmedi.", notFound) : names
    }
}
