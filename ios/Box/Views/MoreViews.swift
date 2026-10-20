import PhotosUI
import SwiftUI

// MARK: - Etiket düzenleyici

struct TagEditorView: View {
    let track: Track

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var cover: UIImage?
    @State private var removeCover = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                Group {
                                    if let cover {
                                        Image(uiImage: cover).resizable().scaledToFill()
                                    } else if removeCover {
                                        ArtworkPlaceholder()
                                    } else {
                                        ArtworkFill(url: track.url, maxSide: 600)
                                    }
                                }
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.black)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Color.white))
                                    .padding(8)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Bilgiler") {
                    TextField("Şarkı adı", text: $title)
                    TextField("Sanatçı", text: $artist)
                    TextField("Albüm", text: $album)
                }
                .listRowBackground(Color.boxSurface2)

                Section {
                    Button("Kapağı kaldır", role: .destructive) {
                        cover = nil
                        removeCover = true
                    }
                    Button("Orijinal bilgilere dön") {
                        library.resetTags(of: track)
                        dismiss()
                    }
                } footer: {
                    Text("Değişiklikler yalnızca Box'ta görünür; dosyanın kendisine dokunulmaz.")
                }
                .listRowBackground(Color.boxSurface2)
            }
            .scrollContentBackground(.hidden)
            .background(Color.boxSurface.ignoresSafeArea())
            .navigationTitle("Bilgileri düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kaydet") {
                        library.editTags(of: track, title: title, artist: artist, album: album, cover: cover, removeCover: removeCover)
                        Haptics.success()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                title = track.title
                artist = track.artist
                album = track.album
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        cover = image
                        removeCover = false
                    }
                }
            }
        }
    }
}

// MARK: - Box Özeti

struct SummaryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var range: Range = .month
    @State private var shareImage: UIImage?

    enum Range: String, CaseIterable, Hashable {
        case week = "Bu hafta", month = "Bu ay", year = "Bu yıl", all = "Tümü"
        var days: Int? { switch self { case .week: return 7; case .month: return 30; case .year: return 365; case .all: return nil } }
    }

    private var totalSeconds: Double {
        guard let days = range.days else { return library.stats.byDay.values.reduce(0, +) }
        let cutoff = LibraryStore.dayKey(Date().addingTimeInterval(-Double(days) * 86400))
        return library.stats.byDay.filter { $0.key >= cutoff }.values.reduce(0, +)
    }

    private var activeDays: Int {
        guard let days = range.days else { return library.stats.byDay.count }
        let cutoff = LibraryStore.dayKey(Date().addingTimeInterval(-Double(days) * 86400))
        return library.stats.byDay.filter { $0.key >= cutoff && $0.value > 60 }.count
    }

    private var topArtists: [(String, Double)] {
        library.stats.byArtist.filter { $0.key != "Bilinmeyen sanatçı" }.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    private var topTracks: [(String, String, Double)] {
        library.stats.byTrack.sorted { $0.value > $1.value }.prefix(5).map { item in
            let track = library.resolve(path: item.key)
            return (track?.title ?? library.stats.titles[item.key] ?? "Şarkı", track?.displayArtist ?? "", item.value)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ChipBar(items: Range.allCases, selection: $range) { $0.rawValue }
                    .padding(.horizontal, -16)

                card
                    .padding(.top, 4)

                if totalSeconds < 60 {
                    Text("Box'ta müzik dinledikçe burası dolacak. İstatistikler sadece bu telefonda tutulur.")
                        .font(.subheadline)
                        .foregroundColor(.boxSecondaryText)
                }

                Button {
                    let renderer = ImageRenderer(content: card.frame(width: 360).padding(20).background(Color.boxBackground))
                    renderer.scale = 3
                    shareImage = renderer.uiImage
                } label: {
                    Label("Kartı paylaş", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(totalSeconds < 60)
            }
            .padding(16)
        }
        .boxScreenBackground()
        .navigationTitle("Box Özeti")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { shareImage.map(ShareImage.init) }, set: { shareImage = $0?.image })) { item in
            ShareSheet(items: [item.image])
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                BoxWordmark(markSize: 20)
                Spacer()
                Text(range.rawValue.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundColor(.black.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(totalSeconds / 60))")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundColor(.black)
                Text("dakika müzik • \(activeDays) gün")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black.opacity(0.7))
            }
            if !topArtists.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EN ÇOK DİNLEDİĞİN SANATÇILAR").font(.system(size: 11, weight: .bold)).tracking(1).foregroundColor(.black.opacity(0.55))
                    ForEach(Array(topArtists.enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text("\(index + 1)").font(.system(size: 15, weight: .heavy)).frame(width: 20, alignment: .leading)
                            Text(item.0).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text("\(Int(item.1 / 60)) dk").font(.system(size: 13, weight: .medium)).opacity(0.6)
                        }
                        .foregroundColor(.black)
                    }
                }
            }
            if !topTracks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EN ÇOK DİNLEDİĞİN ŞARKILAR").font(.system(size: 11, weight: .bold)).tracking(1).foregroundColor(.black.opacity(0.55))
                    ForEach(Array(topTracks.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1)").font(.system(size: 15, weight: .heavy)).frame(width: 20, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.0).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                if !item.1.isEmpty { Text(item.1).font(.system(size: 12)).opacity(0.6).lineLimit(1) }
                            }
                            Spacer()
                        }
                        .foregroundColor(.black)
                    }
                }
            }
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Color.accent, Color(red: 0.62, green: 0.95, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ShareImage: Identifiable {
    let image: UIImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}
