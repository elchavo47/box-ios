import SwiftUI
import UIKit

/// Satın almadan sonra: "Premium açıldı, şu özelliklerin kilidi açıldı" penceresi.
/// Kendi penceresinde açılır; açık sayfaların (Premium ekranı, oynatıcı) üstünde görünür.
@MainActor
final class UnlockPresenter: ObservableObject {
    static let shared = UnlockPresenter()

    struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
    }

    @Published fileprivate(set) var items: [Item] = []
    @Published fileprivate(set) var visible = false
    private var window: UIWindow?
    private var onClose: (() -> Void)?

    /// Hesapta açık olan Premium özelliklerinden pencere maddeleri.
    static func items(for features: [String]?) -> [Item] {
        let catalog: [Item] = [
            Item(id: "eq", icon: "slider.vertical.3", title: L("10 bantlı ekolayzer"), detail: L("Hazır ayarlar ve ses yükseltme, çalan şarkı ekranında.")),
            Item(id: "vault", icon: "lock.shield.fill", title: L("Kilitli klasör"), detail: L("Özel dosyaların {0} ile açılan klasörde.", VaultStore.shared.biometryName)),
            Item(id: "browser", icon: "arrow.down.circle.fill", title: L("Tarayıcıdan dosya indir"), detail: L("İndirdiğin ses dosyaları doğrudan Box'a.")),
            Item(id: "search", icon: "magnifyingglass", title: L("Arama"), detail: L("Şarkı, sanatçı ve albüm ara.")),
            Item(id: "stream", icon: "play.circle.fill", title: L("İnternetten dinle"), detail: L("İndirmeden çal.")),
            Item(id: "download", icon: "arrow.down.to.line", title: L("Şarkı indir"), detail: L("Kitaplığa ekle, internetsiz çal.")),
            Item(id: "radio", icon: "dot.radiowaves.left.and.right", title: L("Radyo"), detail: L("Sıra bitince benzerleriyle devam.")),
        ]
        guard let features else { return catalog }
        let set = Set(features)
        return catalog.filter { set.contains($0.id) }
    }

    func show(features: [String]?, onClose: @escaping () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            onClose()
            return
        }
        items = Self.items(for: features)
        self.onClose = onClose
        if window == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: UnlockHost(presenter: self)
                .environment(\.layoutDirection, Lang.shared.layoutDirection)
                .environment(\.locale, Lang.shared.locale))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.makeKeyAndVisible()
            self.window = window
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.async { self.visible = true }
    }

    func dismiss() {
        guard visible else { return }
        visible = false
        let done = onClose
        onClose = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            done?()
            guard let self, !self.visible else { return }
            self.window?.isHidden = true
            self.window = nil
        }
    }
}

private struct UnlockHost: View {
    @ObservedObject var presenter: UnlockPresenter
    @State private var revealed = 0
    @State private var glow = false

    var body: some View {
        ZStack {
            if presenter.visible {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
                    .transition(.opacity)

                card
                    .padding(.horizontal, 22)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: presenter.visible)
        .onChange(of: presenter.visible) { visible in
            guard visible else { revealed = 0; return }
            glow = true
            for index in 0...presenter.items.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(index) * 0.12) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { revealed = index + 1 }
                    if index < presenter.items.count { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.25))
                    .frame(width: 120, height: 120)
                    .blur(radius: 24)
                    .scaleEffect(glow ? 1.15 : 0.8)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glow)
                BoxMark(size: 62)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.accent)
                    .background(Circle().fill(Color.boxSurface).padding(2))
                    .offset(x: 30, y: 26)
            }
            .frame(height: 110)

            VStack(spacing: 6) {
                Text(L("Premium açıldı"))
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(.white)
                Text(L("Şu özelliklerin kilidi açıldı:"))
                    .font(.system(size: 15))
                    .foregroundColor(.boxSecondaryText)
            }

            VStack(spacing: 10) {
                ForEach(Array(presenter.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accent)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.accentSoft))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            Text(item.detail).font(.system(size: 13)).foregroundColor(.boxSecondaryText).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.accent)
                    }
                    .opacity(revealed > index ? 1 : 0)
                    .offset(y: revealed > index ? 0 : 12)
                }
            }

            Button { presenter.dismiss() } label: { Text(L("Harika, başlayalım")) }
                .buttonStyle(PrimaryButtonStyle())
                .opacity(revealed > presenter.items.count ? 1 : 0.4)
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.boxSurface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.accent.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }
}
