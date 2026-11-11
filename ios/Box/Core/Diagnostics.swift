import Foundation
import MetricKit

/// MetricKit'in çökme, donma, aşırı CPU ve disk yazma raporlarını toplar ve sunucunun hata kayıtlarına
/// (panel > Hatalar) gönderir. Raporlar çökmeden sonraki açılışta ya da en geç yaklaşık 24 saat içinde gelir.
/// Gönderilemeyen rapor diskte bekler ve bir sonraki açılışta yeniden denenir.
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsReporter()

    private struct Ack: Decodable { let ok: Bool }

    private let queueFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    func start() {
        MXMetricManager.shared.add(self)
        Task { await flushQueue() }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        for payload in payloads {
            let data = payload.jsonRepresentation()
            guard data.count < 800_000 else { continue }
            try? data.write(to: queueFolder.appendingPathComponent(UUID().uuidString + ".json"))
        }
        Task { await flushQueue() }
    }

    private func flushQueue() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: queueFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files.prefix(10) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                let _: Ack = try await APIClient.shared.send("diagnostics", method: "POST", bodyData: data)
                try? FileManager.default.removeItem(at: file)
            } catch let error as APIError where (400..<500).contains(error.status) && error.status != 429 {
                // Sunucu raporu kabul etmiyor: sonsuza kadar tekrar denemeye gerek yok.
                try? FileManager.default.removeItem(at: file)
            } catch {
                // Ağ yok ya da sunucu geçici olarak yanıt vermiyor: bir sonraki açılışta tekrar denenir.
            }
        }
    }
}
