import PhotosUI
import SwiftUI

enum PlaylistSource: Hashable {
    case playlist(UUID)
    case favorites
    case tracks(title: String, icon: String, tracks: [Track])

    var isEditable: Bool {
        if case .playlist = self { return true }
        return false
    }
}

struct PlaylistDetailView: View {
    let source: PlaylistSource

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var stream: StreamCache
    @Environment(\.dismiss) private var dismiss

    private var missing: [SearchResult] { tracks.compactMap(\.remote) }
    private var activeDownloads: Int { missing.filter { downloads.state(for: $0.id)?.isActive == true }.count }

    @State private var showPicker = false
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    private var playlist: Playlist? {
        if case .playlist(let id) = source { return library.playlist(id) }
        return nil
    }

    private var title: String {
        switch source {
        case .favorites: return "Beğenilenler"
        case .playlist: return playlist?.name ?? "Liste"
        case .tracks(let title, _, _): return title
        }
    }

    private var tracks: [Track] {
        switch source {
        case .favorites: return library.favoriteTracks
        case .playlist: return playlist.map { library.tracks(for: $0) } ?? []
        case .tracks(_, _, let tracks):
            // Kitaplık değiştiyse güncel kopyaları kullan.
            return tracks.compactMap { library.track(forPath: $0.relativePath) }
        }
    }

    private var icon: String {
        switch source {
        case .favorites: return "heart.fill"
        case .playlist: return "music.note.list"
        case .tracks(_, let icon, _): return icon
        }
    }

    private var totalDuration: Double {
        tracks.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if tracks.isEmpty {
                    EmptyStateView(
                        icon: source == .favorites ? "heart" : "music.note.list",
                        title: "Liste boş",
                        message: source == .favorites
                            ? "Çalarken kalbe dokunduğun şarkılar burada görünür."
                            : (source.isEditable ? "Sağ üstteki menüden şarkı ekle." : "Burada henüz şarkı yok.")
                    )
                    .listRowBackground(Color.clear)
                }

                ForEach(tracks) { track in
                    TrackRow(track: track)
                        .listRowBackground(Color.clear)
                        .onTapGesture {
                            player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                        }
                }
                .onDelete(perform: source.isEditable || source == .favorites ? delete : nil)
                .onMove(perform: source.isEditable ? move : nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .boxScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: missing.count) { stream.warm(missing, limit: 8) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item, case .playlist(let id) = source else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    library.setCover(image, for: id)
                    Haptics.success()
                }
                photoItem = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if case .playlist = source {
                    EditButton()
                    Menu {
                        if let remote = tracks.compactMap(\.remote) as [SearchResult]?, !remote.isEmpty {
                            Button {
                                downloads.download(all: remote)
                                Haptics.success()
                            } label: {
                                Label("İndirilmemiş \(remote.count) şarkıyı indir", systemImage: "arrow.down.circle")
                            }
                        }
                        Button {
                            showPicker = true
                        } label: {
                            Label("Şarkı ekle", systemImage: "plus")
                        }
                        Button {
                            renameText = playlist?.name ?? ""
                            showRename = true
                        } label: {
                            Label("Yeniden adlandır", systemImage: "pencil")
                        }
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Kapak resmini değiştir", systemImage: "photo")
                        }
                        if playlist?.coverFile != nil, case .playlist(let id) = source {
                            Button {
                                library.removeCover(for: id)
                            } label: {
                                Label("Kapak resmini kaldır", systemImage: "photo.badge.minus")
                            }
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Listeyi sil", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            if case .playlist(let id) = source {
                TrackPickerView(existing: Set(playlist?.paths ?? [])) { selected in
                    library.add(selected, to: id)
                }
            }
        }
        .alert("Listeyi yeniden adlandır", isPresented: $showRename) {
            TextField("Liste adı", text: $renameText)
            Button("Kaydet") {
                if case .playlist(let id) = source {
                    library.renamePlaylist(id, to: renameText.trimmingCharacters(in: .whitespaces))
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .confirmationDialog("Bu liste silinsin mi? Şarkılar silinmez.", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Listeyi sil", role: .destructive) {
                if case .playlist(let id) = source {
                    library.deletePlaylist(id)
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Group {
                if let playlist {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        PlaylistArtwork(playlist: playlist, tracks: tracks, size: 210, cornerRadius: 10)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.black)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(Color.white))
                                    .padding(10)
                            }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Kapak resmini değiştir")
                } else {
                    PlaylistCover(tracks: tracks, icon: icon, size: 210, cornerRadius: 10)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 22, y: 12)

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(tracks.count) şarkı • \(Formatters.longDuration(totalDuration))")
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
            }

            HStack(spacing: 12) {
                Button {
                    player.play(tracks, startAt: 0)
                } label: {
                    Label("Çal", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    player.play(tracks, startAt: 0, shuffled: true)
                } label: {
                    Label("Karıştır", systemImage: "shuffle")
                }
                .buttonStyle(PrimaryButtonStyle(filled: false))

                if !missing.isEmpty || activeDownloads > 0 {
                    Button {
                        downloads.download(all: missing)
                        Haptics.success()
                    } label: {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.1))
                            if activeDownloads > 0 {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: 46, height: 46)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("İndirilmemiş \(missing.count) şarkıyı indir")
                }
            }
            .disabled(tracks.isEmpty)
            .opacity(tracks.isEmpty ? 0.5 : 1)

            if !missing.isEmpty {
                Text(activeDownloads > 0 ? "\(activeDownloads) şarkı iniyor • \(missing.count) indirilmedi" : "\(missing.count) şarkı indirilmedi • internetten çalar")
                    .font(.footnote)
                    .foregroundColor(.boxSecondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func delete(at offsets: IndexSet) {
        switch source {
        case .favorites:
            for index in offsets where tracks.indices.contains(index) {
                library.toggleFavorite(tracks[index])
            }
        case .playlist(let id):
            library.removeTracks(at: offsets, from: id)
        case .tracks:
            break
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        if case .playlist(let id) = self.source {
            library.moveTracks(from: source, to: destination, in: id)
        }
    }
}

struct TrackPickerView: View {
    let existing: Set<String>
    let onDone: ([Track]) -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var searchText = ""

    private var candidates: [Track] {
        let base = library.tracks.filter { !existing.contains($0.relativePath) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { track in
                Button {
                    if selected.contains(track.id) {
                        selected.remove(track.id)
                    } else {
                        selected.insert(track.id)
                    }
                } label: {
                    HStack {
                        TrackRow(track: track, showMenu: false)
                        Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(selected.contains(track.id) ? .accent : .boxSecondaryText)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .boxScreenBackground()
            .searchable(text: $searchText, prompt: "Ara")
            .navigationTitle("Şarkı ekle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Ekle (\(selected.count))") {
                        let chosen = library.tracks.filter { selected.contains($0.id) }
                        onDone(chosen)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}
