import SwiftUI

enum TrackSort: String, CaseIterable, Identifiable {
    case title = "Ada göre"
    case artist = "Sanatçıya göre"
    case added = "Eklenme tarihine göre"

    var id: String { rawValue }
}

enum LibraryRoute: Hashable {
    case playlist(UUID)
    case favorites
    case allSongs
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    private var filtered: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if library.tracks.isEmpty && !library.isScanning {
                    emptyLibrary
                } else if !searchText.isEmpty {
                    searchResults
                } else {
                    content
                }
            }
            .boxScreenBackground()
            .navigationTitle("Kitaplık")
            .searchable(text: $searchText, prompt: "Şarkı, sanatçı veya albüm")
            .refreshable { await library.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Image("BoxLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .blendMode(.screen)
                        .shadow(color: .neon.opacity(0.6), radius: 6)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if library.isScanning {
                        ProgressView().tint(.neon)
                    }
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .playlist(let id):
                    PlaylistDetailView(source: .playlist(id))
                case .favorites:
                    PlaylistDetailView(source: .favorites)
                case .allSongs:
                    AllSongsView()
                }
            }
            .alert("Yeni çalma listesi", isPresented: $showNewPlaylist) {
                TextField("Liste adı", text: $newPlaylistName)
                Button("Oluştur") {
                    let playlist = library.createPlaylist(name: newPlaylistName.trimmingCharacters(in: .whitespaces))
                    newPlaylistName = ""
                    path.append(LibraryRoute.playlist(playlist.id))
                }
                Button("Vazgeç", role: .cancel) { newPlaylistName = "" }
            }
        }
    }

    // MARK: - Bölümler

    private var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            quickActions
                .padding(.horizontal, 16)
                .padding(.top, 8)

            if !library.recentlyAdded.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Son eklenenler")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(library.recentlyAdded) { track in
                                RecentCard(track: track)
                                    .onTapGesture {
                                        player.play(library.recentlyAdded, startAt: library.recentlyAdded.firstIndex(of: track) ?? 0)
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Çalma listeleri", action: { showNewPlaylist = true }, actionTitle: "Yeni")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        PlaylistCard(
                            title: "Beğenilenler",
                            subtitle: "\(library.favoriteTracks.count) şarkı",
                            tracks: library.favoriteTracks,
                            icon: "heart.fill"
                        )
                        .onTapGesture { path.append(LibraryRoute.favorites) }

                        ForEach(library.playlists) { playlist in
                            let tracks = library.tracks(for: playlist)
                            PlaylistCard(
                                title: playlist.name,
                                subtitle: "\(tracks.count) şarkı",
                                tracks: tracks,
                                icon: "music.note.list"
                            )
                            .onTapGesture { path.append(LibraryRoute.playlist(playlist.id)) }
                        }

                        Button {
                            showNewPlaylist = true
                        } label: {
                            VStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.neon.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                                    .frame(width: 140, height: 140)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .font(.system(size: 30, weight: .semibold))
                                            .foregroundColor(.neon)
                                    )
                                Text("Yeni liste")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Şarkılar", action: { path.append(LibraryRoute.allSongs) }, actionTitle: "Tümü (\(library.tracks.count))")

                LazyVStack(spacing: 0) {
                    ForEach(Array(library.tracks.prefix(20))) { track in
                        TrackRow(track: track)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .onTapGesture {
                                player.play(library.tracks, startAt: library.tracks.firstIndex(of: track) ?? 0)
                            }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                player.play(library.tracks, startAt: 0)
            } label: {
                Label("Tümünü çal", systemImage: "play.fill")
            }
            .buttonStyle(NeonButtonStyle())

            Button {
                player.play(library.tracks, startAt: 0, shuffled: true)
            } label: {
                Label("Karıştır", systemImage: "shuffle")
            }
            .buttonStyle(NeonButtonStyle(filled: false))
        }
        .disabled(library.tracks.isEmpty)
    }

    private var searchResults: some View {
        LazyVStack(spacing: 0) {
            if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "Sonuç yok", message: "\"\(searchText)\" ile eşleşen şarkı bulunamadı.")
            }
            ForEach(filtered) { track in
                TrackRow(track: track)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .onTapGesture {
                        player.play(filtered, startAt: filtered.firstIndex(of: track) ?? 0)
                    }
            }
        }
        .padding(.top, 8)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image("BoxLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .blendMode(.screen)
                .shadow(color: .neon.opacity(0.7), radius: 20)
                .padding(.top, 60)

            Text("Kitaplığın boş")
                .font(.system(.title2, design: .rounded).weight(.bold))

            Text("Müziklerini Dosyalar sekmesinden içe aktar, bilgisayardan Finder/iTunes ile at ya da başka bir uygulamadan \"Box ile aç\" de.")
                .font(.subheadline)
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecentCard: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: track.url, size: 140, cornerRadius: 14)
            Text(track.title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .lineLimit(1)
            Text(track.displayArtist)
                .font(.caption)
                .foregroundColor(.boxSecondaryText)
                .lineLimit(1)
        }
        .frame(width: 140)
    }
}

struct PlaylistCard: View {
    let title: String
    let subtitle: String
    let tracks: [Track]
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistCover(tracks: tracks, icon: icon, size: 140)
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.boxSecondaryText)
        }
        .frame(width: 140)
    }
}

/// İlk dört şarkının kapağından mozaik, yoksa ikon.
struct PlaylistCover: View {
    let tracks: [Track]
    let icon: String
    let size: CGFloat

    var body: some View {
        let covers = Array(tracks.prefix(4))

        ZStack {
            if covers.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(url: covers[0].url, size: size / 2, cornerRadius: 0)
                        ArtworkView(url: covers[1].url, size: size / 2, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(url: covers[2].url, size: size / 2, cornerRadius: 0)
                        ArtworkView(url: covers[3].url, size: size / 2, cornerRadius: 0)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(url: first.url, size: size, cornerRadius: 0)
            } else {
                LinearGradient(colors: [Color.neonDim, Color.boxCard], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon)
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundColor(.neon)
                    .shadow(color: .neon.opacity(0.7), radius: 10)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AllSongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @AppStorage("box.sort") private var sort: TrackSort = .title

    private var sorted: [Track] {
        switch sort {
        case .title:
            return library.tracks
        case .artist:
            return library.tracks.sorted {
                $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist) == .orderedAscending
            }
        case .added:
            return library.tracks.sorted { $0.addedAt > $1.addedAt }
        }
    }

    var body: some View {
        List {
            ForEach(sorted) { track in
                TrackRow(track: track)
                    .listRowBackground(Color.clear)
                    .onTapGesture {
                        player.play(sorted, startAt: sorted.firstIndex(of: track) ?? 0)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .boxScreenBackground()
        .navigationTitle("Tüm şarkılar")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sırala", selection: $sort) {
                        ForEach(TrackSort.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Divider()
                    Button {
                        player.play(sorted, startAt: 0, shuffled: true)
                    } label: {
                        Label("Karıştırarak çal", systemImage: "shuffle")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
        }
    }
}
