import SwiftUI

// MARK: - İlk açılış tanıtımı

struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("folder.badge.plus", "Müziğini getir", "Dosyalar sekmesinden içe aktar, bilgisayardan Finder ile at ya da başka bir uygulamada \"Box ile aç\" de. Klasörlerin olduğu gibi kalır."),
        ("music.note.list", "Kitaplığını düzenle", "Çalma listeleri oluştur, sevdiklerini beğen, kapakları değiştir. Akıllı listeler en çok dinlediklerini kendiliğinden toplar."),
        ("moon.zzz.fill", "Sana göre", "Uyku zamanlayıcısı, şarkı sözleri, radyo, ekolayzer ve dinlediklerine göre öneriler. Hepsi Ayarlar'da."),
    ]

    var body: some View {
        ZStack {
            Color.boxBackground.ignoresSafeArea()
            LinearGradient(colors: [Color.accent.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    BoxWordmark(markSize: 24)
                    Spacer()
                    Button("Geç") { finish() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.boxSecondaryText)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        VStack(spacing: 22) {
                            Spacer()
                            ZStack {
                                Circle().fill(Color.accent.opacity(0.12)).frame(width: 150, height: 150)
                                Image(systemName: pages[index].icon)
                                    .font(.system(size: 60, weight: .semibold))
                                    .foregroundColor(.accent)
                            }
                            Text(pages[index].title)
                                .font(.system(size: 30, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(pages[index].text)
                                .font(.system(size: 17))
                                .foregroundColor(.boxSecondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Color.white : Color.white.opacity(0.25))
                            .frame(width: index == page ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.3), value: page)
                .padding(.bottom, 22)

                Button(page == pages.count - 1 ? "Başla" : "Devam") {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        finish()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func finish() {
        Haptics.success()
        withAnimation(.easeOut(duration: 0.3)) { settings.onboarded = true }
    }
}

// MARK: - Şarkı sözleri

struct LyricsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var service = LyricsService.shared
    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        ZStack {
            Color(player.artworkColor ?? UIColor(red: 0.12, green: 0.2, blue: 0.17, alpha: 1))
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if let track = player.current {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.url, size: 44, cornerRadius: 6, fallback: track.artworkFallback)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text(track.displayArtist).font(.system(size: 13)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                }

                if loading {
                    Spacer()
                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                    Spacer()
                } else if let lyrics {
                    LyricsBody(lyrics: lyrics, clock: player.clock) { player.seek(to: $0) }
                } else {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "text.quote").font(.system(size: 38)).foregroundColor(.white.opacity(0.6))
                        Text("Bu şarkının sözleri bulunamadı").font(.headline)
                        Text("Sözler lrclib.net'ten geliyor; az bilinen şarkılarda olmayabilir.")
                            .font(.subheadline).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .foregroundColor(.white)
        }
        .task(id: player.current?.id) {
            guard let track = player.current else { return }
            loading = true
            lyrics = await service.lyrics(for: track)
            loading = false
        }
    }
}

private struct LyricsBody: View {
    let lyrics: Lyrics
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void

    private var activeIndex: Int? {
        guard lyrics.synced else { return nil }
        let now = clock.currentTime + 0.3
        return lyrics.lines.lastIndex { ($0.time ?? 0) <= now }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(lyrics.lines) { line in
                        let active = line.id == activeIndex
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: lyrics.synced ? 26 : 20, weight: .bold))
                            .foregroundColor(.white.opacity(!lyrics.synced || active ? 1 : 0.38))
                            .scaleEffect(active ? 1.02 : 1, anchor: .leading)
                            .animation(.easeOut(duration: 0.25), value: active)
                            .id(line.id)
                            .onTapGesture {
                                if let time = line.time { onSeek(time) }
                            }
                    }
                    Text(lyrics.synced ? "Sözler: lrclib.net" : "Sözler: lrclib.net • senkron değil")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 20)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 30)
            }
            .onChange(of: activeIndex) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }
}

// MARK: - Bağlantı yok / hata

struct OfflineBanner: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        if !network.isOnline {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                VStack(alignment: .leading, spacing: 1) {
                    Text("İnternet yok").font(.system(size: 14, weight: .semibold))
                    Text("İndirdiklerin ve önbellektekiler çalmaya devam eder.").font(.system(size: 12)).opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.boxSurface2))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
