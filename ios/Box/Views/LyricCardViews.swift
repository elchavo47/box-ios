import SwiftUI

/// Paylaşılabilir şarkı sözü kartı (9:16, hikaye boyutu). ImageRenderer ile görsele çevrilir.
struct LyricCardView: View {
    let title: String
    let artist: String
    let lines: [String]
    let color: UIColor
    let artwork: UIImage?
    let style: Int

    private var fontSize: CGFloat {
        let count = lines.reduce(0) { $0 + $1.count }
        if count > 150 { return 19 }
        if count > 90 { return 23 }
        return 28
    }

    private var background: LinearGradient {
        if style == 1 {
            return LinearGradient(colors: [Color(white: 0.13), Color.black], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color(color), Color(color).opacity(0.55), Color.black.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Group {
                        if let artwork {
                            Image(uiImage: artwork).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.15).overlay(Image(systemName: "music.note").foregroundColor(.white.opacity(0.7)))
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text(artist).font(.system(size: 13)).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 20)

                Image(systemName: "quote.opening")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(style == 1 ? Color.accent : .white.opacity(0.7))
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: fontSize, weight: .heavy))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 20)

                HStack(spacing: 8) {
                    Image("BoxLogo").resizable().scaledToFit().frame(width: 22, height: 22)
                    Text("Box").font(.system(size: 15, weight: .heavy))
                    Spacer()
                    Text(L("Box ile dinliyorum")).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.65))
                }
            }
            .padding(34)
            .foregroundColor(.white)
        }
        .frame(width: 360, height: 640)
    }
}

struct LyricCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let artist: String
    let lines: [String]
    let color: UIColor
    let artwork: UIImage?

    @State private var style = 0
    @State private var shareImage: UIImage?
    @State private var showShare = false

    private var card: LyricCardView {
        LyricCardView(title: title, artist: artist, lines: lines, color: color, artwork: artwork, style: style)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                card
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .scaleEffect(0.66)
                    .frame(width: 360 * 0.66, height: 640 * 0.66)
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

                Picker("", selection: $style) {
                    Text(L("Renkli")).tag(0)
                    Text(L("Koyu")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)

                Button {
                    let renderer = ImageRenderer(content: card)
                    renderer.scale = 3
                    shareImage = renderer.uiImage
                    showShare = shareImage != nil
                } label: {
                    Label(L("Paylaş"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.boxSurface.ignoresSafeArea())
            .navigationTitle(L("Söz kartı"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Bitti")) { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                if let shareImage { ShareSheet(items: [shareImage]) }
            }
        }
    }
}
