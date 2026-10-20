import SwiftUI

// MARK: - Biçimlendirme

enum MusicFormat {
    /// "99M" / "1.2B" / "546K" / "99M plays" → "99 Mn", "1,2 Mr", "546 B".
    static func count(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let space = text.firstIndex(of: " ") { text = String(text[..<space]) }
        let units: [Character: String] = ["K": "B", "M": L("Mn"), "B": L("Mr")]
        if let last = text.last, let unit = units[last.uppercased().first ?? last] {
            let number = String(text.dropLast()).replacingOccurrences(of: ".", with: ",")
            return number.isEmpty ? nil : number + " " + unit
        }
        return text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) ? text.replacingOccurrences(of: ",", with: ".") : nil
    }

    static func albumType(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "single": return L("Single")
        case "ep": return L("EP")
        default: return L("Albüm")
        }
    }

    static func subtitle(for item: MusicItem, inCard: Bool = false) -> String {
        var parts: [String] = []
        switch item.type {
        case .song:
            parts.append(L("Şarkı"))
            if !inCard, let channel = item.channel, !channel.isEmpty { parts.append(channel) }
            if let plays = count(item.views) { parts.append(plays + L(" kez dinlendi")) }
            else if inCard, let duration = item.duration, duration > 0 { parts.append(Formatters.time(Double(duration))) }
        case .video:
            parts.append(L("Video"))
            if let channel = item.channel, !channel.isEmpty { parts.append(channel) }
            if let views = count(item.views) { parts.append(views + L(" görüntüleme")) }
        case .album:
            parts.append(albumType(item.albumType))
            if let channel = item.channel, !channel.isEmpty { parts.append(channel) }
            if let year = item.year, !year.isEmpty { parts.append(year) }
        case .artist:
            parts.append(L("Sanatçı"))
            if let subs = count(item.subscribers) { parts.append(subs + L(" dinleyici")) }
        case .playlist:
            parts.append(L("Çalma listesi"))
            if let author = item.author, !author.isEmpty { parts.append(author) }
        case .other:
            break
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Kapak

/// Kare kapak (videolarda ortadan kare kırpılır), sanatçıda yuvarlak.
struct MusicItemCover: View {
    let item: MusicItem
    var size: CGFloat = 56

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var stream: StreamCache

    private var isCurrent: Bool {
        guard item.isPlayable, let current = player.current else { return false }
        if current.remote?.id == item.itemID { return true }
        return library.videoID(forPath: current.relativePath) == item.itemID
    }

    var body: some View {
        let shape = item.type == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: max(4, size * 0.08), style: .continuous))
        ZStack {
            CachedRemoteImage(url: item.thumbnailURL, maxSide: size * 3) { ArtworkPlaceholder() }
                .frame(width: size, height: size)
                .clipped()
            if isCurrent {
                Color.black.opacity(0.5)
                if player.isBuffering { ProgressView().tint(.white) } else { PlayingBars(animating: player.isPlaying) }
            } else if item.isPlayable, stream.preparing.contains(item.itemID) {
                Color.black.opacity(0.5)
                ProgressView().tint(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

// MARK: - Satır

/// YouTube Music tarzı sonuç satırı: kare kapak, ad, "Şarkı • Sanatçı • 99 Mn kez dinlendi", ⋯ menüsü.
struct MusicResultRow: View {
    let item: MusicItem
    var inCard = false
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    private var track: Track? {
        guard let result = item.result else { return nil }
        return library.localTrack(for: result) ?? .remote(result)
    }

    private var isCurrent: Bool {
        guard let track, let current = player.current else { return false }
        return current.relativePath == track.relativePath || current.remote?.id == item.itemID
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    MusicItemCover(item: item, size: inCard ? 52 : 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(isCurrent ? .accent : .white)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            statusIcon
                            Text(MusicFormat.subtitle(for: item, inCard: inCard))
                                .lineLimit(1)
                        }
                        .font(.system(size: 14))
                        .foregroundColor(.boxSecondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))

            if let track {
                TrackMenu(track: track)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.boxTertiaryText)
                    .frame(width: 36, height: 44)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let result = item.result {
            if library.localTrack(for: result) != nil {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundColor(.accent)
            } else if let state = downloads.state(for: result.id), state.isActive {
                DownloadFillIcon(progress: { if case .downloading(let p) = state { return p }; return nil }(), size: 13)
            } else if library.isFavorite(.remote(result)) {
                Image(systemName: "heart.fill").font(.system(size: 10)).foregroundColor(.accent)
            }
        }
    }
}

// MARK: - En iyi sonuç kartı

struct TopResultCard: View {
    let item: MusicItem
    /// Sonuçlardaki şarkılar (karıştır / çal için).
    let songs: [MusicItem]
    let open: (MusicItem) -> Void
    let play: ([MusicItem], MusicItem?, Bool) -> Void

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore

    private var children: [MusicItem] { (item.children ?? []).filter(\.isPlayable) }

    /// Sanatçının şarkıları: kartın içindekiler, sonra sonuçlarda o sanatçıya ait olanlar.
    private var artistSongs: [MusicItem] {
        var list = children
        let have = Set(list.map(\.itemID))
        list += songs.filter { $0.artistId == item.itemID && !have.contains($0.itemID) }
        return list.isEmpty ? songs : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open(item) } label: {
                HStack(spacing: 14) {
                    MusicItemCover(item: item, size: item.type == .artist ? 64 : 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(MusicFormat.subtitle(for: item))
                            .font(.system(size: 14))
                            .foregroundColor(.boxSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !item.isPlayable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.boxSecondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            buttons
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, children.isEmpty ? 16 : 10)

            if !children.isEmpty {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        MusicResultRow(item: child, inCard: true) { play(artistSongs, child, false) }
                            .padding(.leading, 16)
                            .padding(.trailing, 6)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.03))
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.boxSurface))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            switch item.type {
            case .artist, .album, .playlist:
                Button { play(item.type == .artist ? artistSongs : children, nil, true) } label: { Label(L("Karıştır"), systemImage: "shuffle") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(artistSongs.isEmpty && children.isEmpty)
                Button {
                    if let first = (item.type == .artist ? artistSongs : children).first?.result {
                        player.startRadio(from: library.localTrack(for: first) ?? .remote(first))
                    } else {
                        open(item)
                    }
                } label: { Label(item.type == .artist ? L("Mix") : L("Radyo"), systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(OutlineButtonStyle())
            default:
                Button { play([item] + songs.filter { $0.itemID != item.itemID }, item, false) } label: { Label(L("Çal"), systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    if let result = item.result { player.startRadio(from: library.localTrack(for: result) ?? .remote(result)) }
                } label: { Label(L("Radyo"), systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }
}

/// İnce çerçeveli ikincil düğme (YouTube Music'teki "Mix").
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline).weight(.semibold))
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .foregroundColor(.white)
            .background(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Arama sonuç düzeni

/// Arama filtreleri (YouTube Music'teki çipler + kendi kitaplığın).
enum SearchFilter: String, CaseIterable, Hashable {
    case all, songs, videos, albums, artists, playlists, library

    var title: String {
        switch self {
        case .all: return L("Tümü")
        case .songs: return L("Şarkılar")
        case .videos: return L("Videolar")
        case .albums: return L("Albümler")
        case .artists: return L("Sanatçılar")
        case .playlists: return L("Çalma listeleri")
        case .library: return L("Kitaplığım")
        }
    }

    /// Sunucudaki filtre adı (Tümü ve Şarkılar ana aramadan gelir).
    var serverFilter: String? {
        switch self {
        case .videos, .albums, .artists, .playlists: return rawValue
        default: return nil
        }
    }
}
