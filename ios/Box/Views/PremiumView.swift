import StoreKit
import SwiftUI

/// Box Premium satın alma ekranı. Satın almayla tarayıcıdan dosya indirme açılır.
struct PremiumView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var store = PremiumStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selected = PremiumStore.yearly
    @State private var restoring = false

    private static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacy = URL(string: "https://dev.aydworks.com.tr/gizlilik")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    hero
                    if let info = auth.user?.store {
                        activeCard(info)
                    } else {
                        benefits
                        plans
                        purchaseButton
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .accessibilityLabel(L("Kapat"))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await store.loadProducts() }
        .onChange(of: auth.user?.store) { info in
            if info != nil { Haptics.success() }
        }
    }

    // MARK: Parçalar

    private var background: some View {
        ZStack(alignment: .top) {
            Color.boxBackground
            RadialGradient(colors: [Color.accent.opacity(0.32), .clear], center: .top, startRadius: 0, endRadius: 420)
                .frame(height: 520)
                .blur(radius: 30)
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            BoxMark(size: 64)
                .shadow(color: Color.accent.opacity(0.5), radius: 26)
                .padding(.top, 8)
            Text("Box Premium")
                .font(.system(size: 32, weight: .heavy))
                .foregroundColor(.white)
            Text(L("Ekolayzer, kilitli klasör ve tarayıcıdan indirme. Hepsi bir arada."))
                .font(.system(size: 16))
                .foregroundColor(.boxSecondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 16) {
            benefit("slider.vertical.3", L("10 bantlı ekolayzer"), L("Bas, vokal, rock ve daha fazla hazır ayar, kendi eğrin ve ses yükseltme. Çalan şarkıya anında uygulanır."))
            benefit("lock.shield.fill", L("Kilitli klasör"), L("Özel şarkılarını {0} ile açılan, Dosyalar uygulamasında ve kitaplıkta görünmeyen bir klasörde sakla.", VaultStore.shared.biometryName))
            benefit("arrow.down.circle.fill", L("Tarayıcıdan dosya indir"), L("Tarayıcı sekmesinden indirdiğin ses dosyaları Dosyalar'a ve kitaplığına kendiliğinden eklenir."))
            benefit("sparkles", L("Yeni Premium özellikleri"), L("Box'a eklenen yeni Premium özelliklerini ilk sen kullanırsın."))
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.boxSurface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.boxStroke, lineWidth: 1))
    }

    private func benefit(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Text(text).font(.system(size: 14)).foregroundColor(.boxSecondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var plans: some View {
        if store.products.isEmpty {
            VStack(spacing: 10) {
                if store.isLoading { ProgressView().tint(.white) }
                if let message = store.message {
                    Text(message).font(.footnote).foregroundColor(.boxSecondaryText).multilineTextAlignment(.center)
                    Button(L("Tekrar dene")) { Task { await store.loadProducts() } }
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 12) {
                ForEach(store.products, id: \.id) { product in
                    planCard(product)
                }
            }
        }
    }

    private func planCard(_ product: Product) -> some View {
        let isOn = selected == product.id
        return Button {
            selected = product.id
            Haptics.tap()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(isOn ? Color.accent : Color.white.opacity(0.25), lineWidth: 2).frame(width: 24, height: 24)
                    if isOn { Circle().fill(Color.accent).frame(width: 13, height: 13) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title(for: product)).font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                        if let badge = badge(for: product) {
                            Text(badge)
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.black)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accent))
                        }
                    }
                    Text(detail(for: product)).font(.system(size: 13)).foregroundColor(.boxSecondaryText)
                }
                Spacer(minLength: 8)
                Text(product.displayPrice)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isOn ? Color.accent.opacity(0.12) : Color.boxSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isOn ? Color.accent : Color.boxStroke, lineWidth: isOn ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }

    private func title(for product: Product) -> String {
        switch product.id {
        case PremiumStore.monthly: return L("Aylık")
        case PremiumStore.yearly: return L("Yıllık")
        default: return L("Ömür boyu")
        }
    }

    private func badge(for product: Product) -> String? {
        switch product.id {
        case PremiumStore.yearly: return L("En avantajlı")
        case PremiumStore.lifetime: return L("Tek seferlik")
        default: return nil
        }
    }

    private func detail(for product: Product) -> String {
        switch product.id {
        case PremiumStore.monthly:
            return L("Her ay yenilenir, istediğin zaman iptal et")
        case PremiumStore.yearly:
            let perMonth = (product.price / 12).formatted(product.priceFormatStyle)
            return L("Ayda yaklaşık {0} · her yıl yenilenir", perMonth)
        default:
            return L("Bir kez öde, hep senin")
        }
    }

    private var purchaseButton: some View {
        VStack(spacing: 12) {
            if !auth.isLoggedIn {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.showAccount = true }
                } label: {
                    Text(L("Satın almak için giriş yap"))
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    guard let product = store.product(selected) else { return }
                    Task {
                        if await store.purchase(product) {
                            UnlockPresenter.shared.show(features: auth.user?.features) { dismiss() }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if store.purchasingID != nil { ProgressView().tint(.black) }
                        Text(store.purchasingID != nil ? L("İşleniyor…") : L("Devam et"))
                    }
                    .frame(height: 22)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.products.isEmpty || store.purchasingID != nil)
                .opacity(store.products.isEmpty ? 0.35 : 1)
            }
            if let message = store.message, !store.products.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func activeCard(_ info: BoxUser.StoreInfo) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundColor(.accent)
            Text(L("Premium'un açık"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Group {
                if info.lifetime {
                    Text(L("Ömür boyu Premium"))
                } else if let date = info.expiresDate {
                    Text(L("Yenilenme: {0}", date.formatted(date: .long, time: .omitted)))
                }
            }
            .font(.system(size: 15))
            .foregroundColor(.boxSecondaryText)
            if !info.lifetime {
                Button {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                            try? await AppStore.showManageSubscriptions(in: scene)
                        }
                    }
                } label: {
                    Text(L("Aboneliği yönet"))
                }
                .buttonStyle(PrimaryButtonStyle(filled: false))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.boxSurface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.accent.opacity(0.4), lineWidth: 1))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                restoring = true
                Task {
                    await store.restore()
                    restoring = false
                }
            } label: {
                HStack(spacing: 6) {
                    if restoring { ProgressView().tint(.white).scaleEffect(0.8) }
                    Text(L("Satın alımları geri yükle"))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            }
            .disabled(restoring)

            Text(L("Abonelik, dönem bitmeden en az 24 saat önce iptal edilmezse otomatik yenilenir. Ödeme Apple kimliğinden alınır; aboneliği Ayarlar › Apple Kimliği › Abonelikler bölümünden yönetebilir ya da iptal edebilirsin."))
                .font(.system(size: 11))
                .foregroundColor(.boxTertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Link(L("Kullanım koşulları"), destination: Self.terms)
                Link(L("Gizlilik"), destination: Self.privacy)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.boxSecondaryText)
        }
        .padding(.top, 4)
    }
}
