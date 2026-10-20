import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
}

struct Lyrics: Equatable {
    let lines: [LyricLine]
    let synced: Bool
}

/// lrclib.net'ten (ücretsiz, anahtarsız) şarkı sözleri. Senkron sözler satır satır kayar.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    private var cache: [String: Lyrics?] = [:]

    private struct Response: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    func lyrics(for track: Track) async -> Lyrics? {
        let key = track.relativePath
        if let cached = cache[key] { return cached }
        let title = Self.cleanTitle(track.title)
        let artist = Self.cleanArtist(track.displayArtist)
        var found = await fetch(path: "get", query: ["track_name": title, "artist_name": artist, "duration": track.duration > 0 ? String(Int(track.duration)) : nil])
        if found == nil {
            found = await search(title: title, artist: artist, duration: track.duration)
        }
        cache[key] = found
        return found
    }

    private func fetch(path: String, query: [String: String?]) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/" + path)!
        components.queryItems = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Box/\(AppConfig.shortVersion) (https://aydworks.com.tr)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Self.parse(decoded)
    }

    private func search(title: String, artist: String, duration: Double) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Box/\(AppConfig.shortVersion) (https://aydworks.com.tr)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = try? JSONDecoder().decode([Response].self, from: data) else { return nil }
        // Süresi en yakın, senkron sözü olanı seç.
        let best = list
            .filter { $0.syncedLyrics != nil || $0.plainLyrics != nil }
            .sorted { a, b in
                let da = abs((a.duration ?? 0) - duration), db = abs((b.duration ?? 0) - duration)
                if (a.syncedLyrics != nil) != (b.syncedLyrics != nil) { return a.syncedLyrics != nil }
                return da < db
            }
            .first { duration <= 0 || abs(($0.duration ?? duration) - duration) < 8 }
        return best.flatMap(Self.parse)
    }

    private static func parse(_ response: Response) -> Lyrics? {
        if let synced = response.syncedLyrics, !synced.isEmpty {
            var lines: [LyricLine] = []
            let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
            for raw in synced.components(separatedBy: .newlines) {
                let ns = raw as NSString
                let matches = pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length))
                guard !matches.isEmpty else { continue }
                let text = pattern.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmingCharacters(in: .whitespaces)
                for match in matches {
                    let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                    let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                    lines.append(LyricLine(id: lines.count, time: minutes * 60 + seconds, text: text.isEmpty ? "♪" : text))
                }
            }
            lines.sort { ($0.time ?? 0) < ($1.time ?? 0) }
            lines = lines.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true) }
        }
        if let plain = response.plainLyrics, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines).enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
            return Lyrics(lines: lines, synced: false)
        }
        if response.instrumental == true {
            return Lyrics(lines: [LyricLine(id: 0, time: nil, text: "♪ Enstrümantal ♪")], synced: false)
        }
        return nil
    }

    static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s*(\||#).*$"#, #"(?i)\s*(official|lyrics?|audio|video|klip).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if let range = t.range(of: " - ") { t = String(t[range.upperBound...]) }
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? title : t.trimmingCharacters(in: .whitespaces)
    }

    static func cleanArtist(_ artist: String) -> String {
        artist.replacingOccurrences(of: #"(?i)\s*(-\s*topic|vevo|official)$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"(?i)\s+(ve|feat\.?|ft\.?)\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) ?? artist
    }
}
