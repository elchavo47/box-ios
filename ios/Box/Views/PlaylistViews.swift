import SwiftUI

enum PlaylistSource: Hashable {
    case playlist(UUID)
    case favorites
}

struct PlaylistDetailView: View {
    let source: PlaylistSource

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""

    private var playlist: Playlist? {
        if case .playlist(let id) = source { return library.playlist(id) }
        return nil
    }

    private var title: String {
        switch source {
        case .favorites: return "Beğenilenler"
        case .playlist: return playlist?.name ?? "Liste"
        }
    }

    private var tracks: [Track] {
        switch source {
        case .favorites: return library.favoriteTracks
        case .playlist: return playlist.map { library.tracks(for: $0) } ?? []
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
                            : "Sağ üstteki + ile şarkı ekle."
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
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .boxScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if case .playlist = source {
                    EditButton()
                    Menu {
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
        VStack(spacing: 14) {
            PlaylistCover(tracks: tracks, icon: source == .favorites ? "heart.fill" : "music.note.list", size: 200)
                .shadow(color: .neon.opacity(0.25), radius: 24)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                Text("\(tracks.count) şarkı • \(Formatters.time(totalDuration))")
                    .font(.subheadline)
                    .foregroundColor(.boxSecondaryText)
            }

            HStack(spacing: 12) {
                Button {
                    player.play(tracks, startAt: 0)
                } label: {
                    Label("Çal", systemImage: "play.fill")
                }
                .buttonStyle(NeonButtonStyle())

                Button {
                    player.play(tracks, startAt: 0, shuffled: true)
                } label: {
                    Label("Karıştır", systemImage: "shuffle")
                }
                .buttonStyle(NeonButtonStyle(filled: false))
            }
            .disabled(tracks.isEmpty)
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
                            .foregroundColor(selected.contains(track.id) ? .neon : .boxSecondaryText)
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
