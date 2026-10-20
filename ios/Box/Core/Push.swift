import SwiftUI
import UIKit
import UserNotifications

/// Bildirimler: izin, cihaz kimliğini sunucuya kaydetme, bildirime dokununca ilgili ekranı açma.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    /// Sunucuya kayıt için oturum bilgisi (BoxApp bağlar).
    var tokenProvider: () -> String? = { nil }
    /// Bildirime dokununca açılacak yer ("account", "search" ...).
    var onOpen: ((String) -> Void)?

    private(set) var deviceToken: String?
    private var lastUploaded: String?

    private var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .authorized || status == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Giriş yapınca bir kez sorulur. Reddedilirse bir daha sorulmaz (Ayarlar'dan açılır).
    func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings().authorizationStatus
        if current == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refreshStatus()
    }

    func didRegister(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Task { await upload() }
    }

    /// Cihaz kimliğini hesaba bağla (giriş yapılınca ve her açılışta).
    func upload() async {
        guard let token = deviceToken, let session = tokenProvider() else { return }
        let key = token + "|" + session
        guard key != lastUploaded else { return }
        do {
            _ = try await APIClient.shared.send("me/push", method: "POST", body: ["token": token, "environment": environment], token: session, as: EmptyResponse.self)
            lastUploaded = key
        } catch {
            // Bir sonraki açılışta yeniden denenir.
        }
    }

    /// Çıkış yaparken bu cihaza artık bildirim gelmesin.
    func unregister(session: String) async {
        guard let token = deviceToken else { return }
        lastUploaded = nil
        _ = try? await APIClient.shared.send("me/push", method: "POST", body: ["token": token, "remove": true], token: session, as: EmptyResponse.self)
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    func handle(userInfo: [AnyHashable: Any]) {
        guard let box = userInfo["box"] as? [String: Any], let open = box["open"] as? String else { return }
        onOpen?(open)
    }
}

extension Notification.Name {
    /// Yeni bildirim geldi: bildirim kutusunu yenile.
    static let boxInboxRefresh = Notification.Name("box.inboxRefresh")
}

/// Bildirim kaydı UIKit üzerinden gelir.
final class BoxAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // Uygulama açıkken de bildirim üstten görünsün.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { NotificationCenter.default.post(name: .boxInboxRefresh, object: nil) }
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { PushManager.shared.handle(userInfo: info) }
    }
}
