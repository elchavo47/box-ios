import SwiftUI
import UIKit
import WidgetKit

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: WidgetSnapshot(now: WidgetTrack(title: "Şarkı adı", artist: "Sanatçı", art: nil), playing: true, recent: []))
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = NowPlayingEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private let green = Color(red: 0.12, green: 0.84, blue: 0.38)

private func artImage(_ name: String?) -> UIImage? {
    guard let name, let url = BoxShared.imageURL(name), let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
}

private struct Cover: View {
    let name: String?
    var radius: CGFloat = 14

    var body: some View {
        Group {
            if let image = artImage(name) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.10, green: 0.30, blue: 0.20), Color(red: 0.04, green: 0.10, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(green)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(for: .widget) { color }
        } else {
            self.background(color)
        }
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    private var bg: Color { Color(red: 0.04, green: 0.07, blue: 0.05) }

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            default: small
            }
        }
        .widgetBackground(bg)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.snapshot.playing ? "waveform" : "pause.fill")
            Text(entry.snapshot.playing ? "Çalıyor" : "Duraklatıldı")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(green)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let now = entry.snapshot.now {
                Cover(name: now.art, radius: 12)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(now.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(now.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                statusLine
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            if let now = entry.snapshot.now {
                Cover(name: now.art, radius: 14)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    statusLine
                    Text(now.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    Text(now.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer(minLength: 4)
                    if !entry.snapshot.recent.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(entry.snapshot.recent.prefix(3).enumerated()), id: \.offset) { _, track in
                                Cover(name: track.art, radius: 8)
                                    .frame(width: 34, height: 34)
                            }
                            Text("Son dinlenenler").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                empty
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "music.note").font(.title2).foregroundStyle(green)
            Text("Box").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            Text("Bir şarkı çal").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BoxNowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Box")
        .description("Çalan şarkı ve son dinlenenler.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
