import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        NavigationStack {
            FolderView(folder: library.documents, isRoot: true)
                .navigationDestination(for: URL.self) { url in
                    FolderView(folder: url, isRoot: false)
                }
        }
    }
}

struct FolderView: View {
    let folder: URL
    let isRoot: Bool

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore

    @State private var showPremium = false
    @State private var items: [FileItem] = []
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var moveTarget: FileItem?
    @State private var deleteTarget: FileItem?
    @State private var errorMessage: String?
    @State private var toast: String?

    private var audioItems: [FileItem] { items.filter { $0.isAudio && !$0.isDirectory } }

    var body: some View {
        List {
            if isRoot {
                NavigationLink {
                    VaultView()
                } label: {
                    VaultEntryRow()
                }
                .listRowBackground(Color.clear)
            }

            if items.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: L("Klasör boş"),
                    message: L("Sağ üstteki + ile dosya içe aktar ya da yeni klasör oluştur.")
                )
                .listRowBackground(Color.clear)
            }

            ForEach(items) { item in
                row(for: item)
                    .listRowBackground(Color.clear)
                    .contextMenu { menu(for: item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = item
                        } label: {
                            Label(L("Sil"), systemImage: "trash")
                        }
                        Button {
                            startRename(item)
                        } label: {
                            Label(L("Adlandır"), systemImage: "pencil")
                        }
                        .tint(.gray)
                    }
            }

            if isRoot {
                Text(L("Bu klasör iPhone'daki Dosyalar uygulamasında \"Bu iPhone'da › Box\" altında da görünür. Bilgisayardan Finder ile dosya atabilirsin."))
                    .font(.footnote)
                    .foregroundColor(.boxSecondaryText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .boxScreenBackground()
        .navigationTitle(isRoot ? L("Dosyalar") : folder.lastPathComponent)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .refreshable { reload() }
        .onAppear { reload() }
        .onChange(of: library.tracks) { _ in reload() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isRoot { AccountButton() }
                if !audioItems.isEmpty {
                    Button {
                        playFolder(startingWith: nil, shuffled: true)
                    } label: {
                        Image(systemName: "shuffle")
                    }
                }

                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label(L("Dosya içe aktar"), systemImage: "square.and.arrow.down")
                    }
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label(L("Yeni klasör"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showPremium) { PremiumView() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let count = await library.importFiles(urls, into: folder)
                reload()
                showToast(count > 0 ? L("{0} dosya içe aktarıldı", count) : L("Yeni dosya eklenmedi"))
            }
        }
        .alert(L("Yeni klasör"), isPresented: $showNewFolder) {
            TextField(L("Klasör adı"), text: $newFolderName)
            Button(L("Oluştur")) {
                perform { _ = try FileService.createFolder(named: newFolderName, in: folder) }
            }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .alert(L("Yeniden adlandır"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(L("Yeni ad"), text: $renameText)
            Button(L("Kaydet")) {
                guard let target = renameTarget else { return }
                perform {
                    let newURL = try FileService.rename(target.url, to: renameText)
                    library.pathMoved(from: target.url, to: newURL)
                    await ArtworkCache.shared.invalidate(target.url)
                }
            }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .boxConfirm(
            deleteTarget.map { L("\"{0}\" silinsin mi?", $0.name) } ?? "",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            icon: deleteTarget?.isDirectory == true ? "folder.badge.minus" : "trash",
            message: deleteTarget?.isDirectory == true ? L("Klasörün içindeki her şey silinir.") : nil,
            confirmTitle: L("Sil")
        ) {
            guard let target = deleteTarget else { return }
            perform {
                try FileService.delete(target.url)
                library.pathDeleted(target.url)
            }
        }
        .sheet(item: $moveTarget) { item in
            FolderPickerView(excluding: item.url) { destination in
                perform {
                    let newURL = try FileService.move(item.url, to: destination)
                    library.pathMoved(from: item.url, to: newURL)
                }
            }
        }
        .alert(L("İşlem yapılamadı"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L("Tamam"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Satırlar

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        if item.isDirectory {
            NavigationLink(value: item.url) {
                HStack(spacing: 12) {
                    Image(systemName: item.name == AppConfig.downloadsFolderName ? "arrow.down.circle.fill" : "folder.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accent)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.boxSurface2))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 16, weight: .medium))
                            .lineLimit(1)
                        Text(L("{0} öğe", item.childCount))
                            .font(.subheadline)
                            .foregroundColor(.boxSecondaryText)
                    }
                }
            }
        } else if item.isAudio, let track = library.track(forPath: library.relativePath(for: item.url)) {
            TrackRow(track: track, showMenu: false)
                .onTapGesture { playFolder(startingWith: item, shuffled: false) }
        } else {
            HStack(spacing: 12) {
                Image(systemName: item.isAudio ? "music.note" : "doc.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.boxSecondaryText)
                    .frame(width: 50, height: 50)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.boxSurface2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 16))
                        .lineLimit(1)
                    Text(Formatters.bytes(item.size))
                        .font(.subheadline)
                        .foregroundColor(.boxSecondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if item.isAudio, !item.isDirectory {
            Button {
                playFolder(startingWith: item, shuffled: false)
            } label: {
                Label(L("Çal"), systemImage: "play.fill")
            }
            if let track = library.track(forPath: library.relativePath(for: item.url)) {
                Button {
                    player.addToQueue(track)
                } label: {
                    Label(L("Sıraya ekle"), systemImage: "text.append")
                }
            }
        }

        Button {
            startRename(item)
        } label: {
            Label(L("Yeniden adlandır"), systemImage: "pencil")
        }

        Button {
            moveTarget = item
        } label: {
            Label(L("Taşı"), systemImage: "folder")
        }

        if !item.isDirectory {
            ShareLink(item: item.url) {
                Label(L("Paylaş"), systemImage: "square.and.arrow.up")
            }
        }

        Button {
            moveToVault(item)
        } label: {
            Label(L("Kilitli klasöre taşı"), systemImage: "lock.fill")
        }

        Button(role: .destructive) {
            deleteTarget = item
        } label: {
            Label(L("Sil"), systemImage: "trash")
        }
    }

    /// Dosyayı / klasörü kilitli klasöre taşır: kitaplıktan, listelerden ve Dosyalar uygulamasından kalkar.
    private func moveToVault(_ item: FileItem) {
        guard auth.has(.vault) else {
            if auth.isPremium {
                showToast(L("Kilitli klasör hesabında kapalı."))
            } else {
                showPremium = true
            }
            return
        }
        perform {
            if let current = player.current?.url.standardizedFileURL.path {
                let path = item.url.standardizedFileURL.path
                if current == path || (item.isDirectory && current.hasPrefix(path + "/")) { player.stop() }
            }
            library.pathDeleted(item.url)
            try VaultStore.shared.moveIn(item.url)
            await ArtworkCache.shared.invalidate(item.url)
        }
        showToast(L("Kilitli klasöre taşındı"))
    }

    // MARK: - İşlemler

    private func reload() {
        items = FileService.list(folder)
    }

    private func startRename(_ item: FileItem) {
        renameText = item.isDirectory ? item.name : (item.name as NSString).deletingPathExtension
        renameTarget = item
    }

    private func playFolder(startingWith item: FileItem?, shuffled: Bool) {
        let tracks = audioItems.compactMap { library.track(forPath: library.relativePath(for: $0.url)) }
        guard !tracks.isEmpty else { return }

        var index = 0
        if let item, let found = tracks.firstIndex(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) {
            index = found
        }

        player.play(tracks, startAt: index, shuffled: shuffled)
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
                await library.refresh()
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }
}

struct FolderPickerView: View {
    let excluding: URL
    let onPick: (URL) -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var folders: [URL] {
        let excluded = excluding.standardizedFileURL.path
        return FileService.folders(in: library.documents).filter {
            let path = $0.standardizedFileURL.path
            return path != excluded && !path.hasPrefix(excluded + "/")
                && $0.standardizedFileURL != excluding.deletingLastPathComponent().standardizedFileURL
        }
    }

    var body: some View {
        NavigationStack {
            List(folders, id: \.self) { url in
                Button {
                    onPick(url)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: url == library.documents ? "house.fill" : "folder.fill")
                            .foregroundColor(.neon)
                        Text(url == library.documents ? L("Box (ana klasör)") : library.relativePath(for: url))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
                .listRowBackground(Color.boxCard)
            }
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .navigationTitle(L("Nereye taşınsın?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Vazgeç")) { dismiss() }
                }
            }
        }
    }
}
