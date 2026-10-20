import SwiftUI

/// Kullanıcının profil fotoğrafı; yoksa adının baş harfi.
struct UserAvatar: View {
    let user: BoxUser?
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(Color.accentDeep)
            Text(String((user?.name ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundColor(.white)
            if let url = user?.avatarURL {
                CachedRemoteImage(url: url, maxSide: size * UIScreen.main.scale) { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

// MARK: - Profil fotoğrafını ayarla

/// Seçilen fotoğrafı yüklemeden önce yuvarlak çerçeveye göre ayarlama ekranı:
/// sürükle, iki parmakla yakınlaştır, çift dokun, 90° döndür.
struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var working: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    init(image: UIImage, onCancel: @escaping () -> Void, onDone: @escaping (UIImage) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onDone = onDone
        _working = State(initialValue: image)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 40, 360)
            VStack(spacing: 0) {
                HStack {
                    Button(L("Vazgeç"), action: onCancel)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                    Text(L("Fotoğrafı ayarla"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        rotate()
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L("Döndür"))
                }
                .padding(.horizontal, 20)
                .frame(height: 56)

                Spacer(minLength: 0)

                cropArea(side: side)

                Spacer(minLength: 0)

                Text(L("Sürükleyerek ve iki parmakla yakınlaştırarak ayarla"))
                    .font(.system(size: 13))
                    .foregroundColor(.boxSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)

                Button {
                    Haptics.success()
                    onDone(render(side: side))
                } label: {
                    Text(L("Kullan"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func cropArea(side: CGFloat) -> some View {
        let base = baseScale(side: side)
        let size = CGSize(width: working.size.width * base * scale, height: working.size.height * base * scale)

        return ZStack {
            Image(uiImage: working)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .offset(offset)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .clipped()
        .overlay(
            // Çemberin dışı karartılır; yüklenecek kısım çemberin içi.
            ZStack {
                Rectangle().fill(Color.black.opacity(0.55))
                Circle().blendMode(.destinationOut)
            }
            .compositingGroup()
            .allowsHitTesting(false)
        )
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).allowsHitTesting(false))
        .gesture(
            SimultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = clamp(CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height), side: side, scale: scale)
                    }
                    .onEnded { _ in lastOffset = offset },
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value, 1), maxScale)
                        offset = clamp(offset, side: side, scale: scale)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        lastOffset = offset
                    }
            )
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                scale = scale > 1.2 ? 1 : 2
                offset = clamp(offset, side: side, scale: scale)
            }
            lastScale = scale
            lastOffset = offset
        }
    }

    /// Kısa kenarı çerçeveyi tam dolduracak ölçek.
    private func baseScale(side: CGFloat) -> CGFloat {
        let shortest = max(1, min(working.size.width, working.size.height))
        return side / shortest
    }

    /// Fotoğraf çerçevenin dışına kayıp boşluk bırakmasın.
    private func clamp(_ proposed: CGSize, side: CGFloat, scale: CGFloat) -> CGSize {
        let base = baseScale(side: side)
        let maxX = max(0, (working.size.width * base * scale - side) / 2)
        let maxY = max(0, (working.size.height * base * scale - side) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    private func rotate() {
        let source = working
        let size = CGSize(width: source.size.height, height: source.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = source.scale
        let rotated = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: .pi / 2)
            source.draw(in: CGRect(x: -source.size.width / 2, y: -source.size.height / 2, width: source.size.width, height: source.size.height))
        }
        Haptics.tap()
        withAnimation(.easeInOut(duration: 0.2)) {
            working = rotated
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }

    /// Çerçevenin içindeki kısmı 512×512 kare olarak çıkarır.
    private func render(side: CGFloat) -> UIImage {
        let factor = baseScale(side: side) * scale
        let visible = side / factor
        let origin = CGPoint(
            x: working.size.width / 2 - offset.width / factor - visible / 2,
            y: working.size.height / 2 - offset.height / factor - visible / 2
        )
        let output: CGFloat = 512
        let k = output / visible
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            working.draw(in: CGRect(x: -origin.x * k, y: -origin.y * k, width: working.size.width * k, height: working.size.height * k))
        }
    }
}
