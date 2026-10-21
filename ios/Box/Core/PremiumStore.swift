import Foundation
import StoreKit

/// App Store'dan Premium satın alma (StoreKit 2).
///
/// Satın alma sunucuda Apple imzasıyla doğrulanır ve hesaba bağlanır; Premium'u ve özelliklerini
/// sunucu belirler. Satın almayla tarayıcıdan indirme açılır. YouTube özellikleri satın almayla
/// gelmez, panelden ayrıca açılır.
@MainActor
final class PremiumStore: ObservableObject {
    static let shared = PremiumStore()

    enum Plan: Int { case monthly, yearly, lifetime }

    /// App Store Connect'teki olası ürün kimlikleri. Hangileri varsa onlar gelir; türü (aylık, yıllık,
    /// tek seferlik) kimlikten değil Apple'ın verdiği bilgiden anlaşılır.
    static let productIDs: [String] = {
        var ids: [String] = []
        for base in ["com.aydworks.box.premium", "com.aydworks.premium", "com.aydworks.box"] {
            for tail in ["monthly", "month", "aylik", "yearly", "year", "annual", "yillik", "lifetime", "omurboyu"] {
                ids.append("\(base).\(tail)")
            }
        }
        return ids
    }()

    static func plan(of product: Product) -> Plan? {
        switch product.type {
        case .nonConsumable:
            return .lifetime
        case .autoRenewable:
            guard let period = product.subscription?.subscriptionPeriod else { return nil }
            if period.unit == .year { return .yearly }
            if period.unit == .month && period.value == 1 { return .monthly }
            return nil
        default:
            return nil
        }
    }

    func plan(_ plan: Plan) -> Product? { products.first { Self.plan(of: $0) == plan } }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var purchasingID: String?
    @Published var message: String?

    /// Hesap bilgisi (giriş yapılmış mı, token, kullanıcıyı güncelleme).
    weak var auth: AuthStore?
    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// Uygulama açılınca: yenilemeler, iadeler ve bekleyen (ör. aile onayı) satın almalar.
    func start(auth: AuthStore) {
        self.auth = auth
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result, silent: true)
            }
        }
    }

    func loadProducts() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            // Her türden bir paket: aylık, yıllık, ömür boyu sırasıyla.
            var byPlan: [Plan: Product] = [:]
            for product in loaded {
                if let plan = Self.plan(of: product), byPlan[plan] == nil { byPlan[plan] = product }
            }
            products = [Plan.monthly, .yearly, .lifetime].compactMap { byPlan[$0] }
            if products.isEmpty { message = L("Paketler şu an yüklenemedi. Biraz sonra tekrar dene.") }
        } catch {
            message = L("Paketler şu an yüklenemedi. Biraz sonra tekrar dene.")
        }
    }

    func purchase(_ product: Product) async -> Bool {
        guard let auth, auth.isLoggedIn else {
            message = L("Satın almak için önce giriş yap.")
            return false
        }
        purchasingID = product.id
        defer { purchasingID = nil }
        var options: Set<Product.PurchaseOption> = []
        if let raw = auth.user?.storeToken, let token = UUID(uuidString: raw) {
            options.insert(.appAccountToken(token))
        }
        do {
            switch try await product.purchase(options: options) {
            case .success(let result):
                return await handle(result, silent: false)
            case .pending:
                message = L("Satın alma onay bekliyor. Onaylanınca Premium kendiliğinden açılır.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = L("Satın alma tamamlanamadı: {0}", error.localizedDescription)
        }
        return false
    }

    /// "Satın alımları geri yükle": Apple'dan eşitle ve etkin satın alımları sunucuya bildir.
    func restore() async {
        guard auth?.isLoggedIn == true else {
            message = L("Geri yüklemek için önce giriş yap.")
            return
        }
        try? await AppStore.sync()
        var sent = false
        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                sent = await handle(result, silent: true) || sent
            }
        }
        message = sent ? L("Satın alımların geri yüklendi.") : L("Bu Apple kimliğinde geri yüklenecek bir satın alma bulunamadı.")
    }

    /// Giriş yapınca: cihazda etkin satın alma varsa ama hesapta görünmüyorsa sessizce bildir.
    func syncIfNeeded() async {
        guard let auth, auth.isLoggedIn, auth.user?.store == nil else { return }
        for await result in Transaction.currentEntitlements {
            if case .verified = result { _ = await handle(result, silent: true) }
        }
    }

    /// İşlemi sunucuya gönderir; sunucu kabul edince StoreKit'e "teslim edildi" denir.
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>, silent: Bool) async -> Bool {
        guard case .verified(let transaction) = result else {
            if !silent { message = L("Satın alma doğrulanamadı.") }
            return false
        }
        guard transaction.productID.hasPrefix("com.aydworks.") else {
            await transaction.finish()
            return false
        }
        guard let auth, let token = auth.token else { return false } // giriş yapılınca tekrar denenir
        do {
            let response: UserResponse = try await APIClient.shared.send(
                "me/purchase", method: "POST", body: ["jws": result.jwsRepresentation], token: token
            )
            auth.apply(response.user)
            await transaction.finish()
            if !silent { message = nil }
            return true
        } catch let error as APIError {
            // Başka hesaba bağlıysa ya da ürün tanınmıyorsa tekrar denemenin anlamı yok.
            if error.status == 422 { await transaction.finish() }
            if !silent { message = error.message }
            return false
        } catch {
            // Ağ hatası: işlem bitirilmez, StoreKit sonra yeniden getirir.
            if !silent { message = L("Satın alma alındı ama sunucuya ulaşılamadı. İnternet gelince kendiliğinden tamamlanır.") }
            return false
        }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }
}
