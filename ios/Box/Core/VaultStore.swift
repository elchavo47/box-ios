import AVFoundation
import Foundation
import LocalAuthentication

/// Kilitli klasör (Premium). Dosyalar Belgeler klasörünün dışında, uygulamanın özel alanında
/// durur: Dosyalar uygulamasında, Finder'da ve kitaplıkta görünmez. Face ID / Touch ID ya da
/// cihaz parolasıyla açılır; uygulama arka plana geçince yeniden kilitlenir.
@MainActor
final class VaultStore: ObservableObject {
    static let shared = VaultStore()
    /// Kilitli klasördeki şarkıların kimlik öneki (kitaplık geçmişine ve istatistiklere girmez).
    static let prefix = "vault:"

    @Published private(set) var isUnlocked = false
    @Published private(set) var revision = 0

    /// Kilitli şarkıları sıradan çıkarmak için.
    var onLock: (() -> Void)?

    let root: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("BoxVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return L("Parola")
        }
    }

    var biometryIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    /// Face ID / Touch ID; olmazsa cihaz parolası.
    @discardableResult
    func unlock() async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        context.localizedCancelTitle = L("Vazgeç")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Cihazda parola yoksa kilitli klasör güvenli olamaz.
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Kilitli klasörü açmak için"))
            isUnlocked = ok
            return ok
        } catch {
            return false
        }
    }

    /// Cihazda parola / Face ID kurulu mu?
    var canLock: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Klasörü kilitler. `stopPlayback`: oradaki şarkılar sıradan çıkarılır (ör. Premium bitince);
    /// arka plana geçerken müzik çalmaya devam eder, yalnızca klasör kilitlenir.
    func lock(stopPlayback: Bool = false) {
        isUnlocked = false
        if stopPlayback { onLock?() }
    }

    func list(_ folder: URL? = nil) -> [FileItem] {
        guard isUnlocked else { return [] }
        return FileService.list(folder ?? root)
    }

    func isInside(_ url: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base)
    }

    /// Dosya ya da klasörü kilitli klasöre taşır.
    @discardableResult
    func moveIn(_ url: URL, to folder: URL? = nil) throws -> URL {
        let target = try FileService.move(url, to: folder ?? root)
        revision += 1
        return target
    }

    /// Kilitli klasörden çıkarır (Box ana klasörüne ya da seçilen klasöre).
    @discardableResult
    func moveOut(_ url: URL, to folder: URL) throws -> URL {
        let target = try FileService.move(url, to: folder)
        revision += 1
        return target
    }

    func delete(_ url: URL) throws {
        try FileService.delete(url)
        revision += 1
    }

    func rename(_ url: URL, to name: String) throws {
        _ = try FileService.rename(url, to: name)
        revision += 1
    }

    func createFolder(named name: String, in folder: URL?) throws {
        _ = try FileService.createFolder(named: name, in: folder ?? root)
        revision += 1
    }

    func relativePath(for url: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        let inner = full.hasPrefix(base) ? String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
        return Self.prefix + inner
    }

    /// Klasördeki ses dosyaları, çalınabilir şarkı olarak.
    func tracks(in items: [FileItem]) async -> [Track] {
        var result: [Track] = []
        for item in items where item.isAudio && !item.isDirectory {
            let asset = AVURLAsset(url: item.url)
            var title = "", artist = "", album = ""
            var duration = 0.0
            if let time = try? await asset.load(.duration), time.isNumeric { duration = time.seconds }
            if let metadata = try? await asset.load(.commonMetadata) {
                for entry in metadata {
                    guard let key = entry.commonKey else { continue }
                    let value = (try? await entry.load(.stringValue)) ?? nil
                    switch key {
                    case .commonKeyTitle: title = value ?? title
                    case .commonKeyArtist: artist = value ?? artist
                    case .commonKeyAlbumName: album = value ?? album
                    default: break
                    }
                }
            }
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = item.url.deletingPathExtension().lastPathComponent }
            result.append(Track(relativePath: relativePath(for: item.url), url: item.url, title: title, artist: artist, album: album, duration: duration, addedAt: item.modified, fileSize: item.size))
        }
        return result
    }
}

extension Track {
    /// Kilitli klasördeki şarkı mı (geçmişe, istatistiklere ve kayıtlı sıraya girmez).
    var isVaulted: Bool { relativePath.hasPrefix(VaultStore.prefix) }
}
