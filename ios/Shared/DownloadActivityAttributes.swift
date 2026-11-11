import ActivityKit
import Foundation

/// Toplu indirme canlı etkinliği (kilit ekranı + Dynamic Island). Uygulama ve eklenti ortak kullanır.
@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Biten şarkı sayısı
        var done: Int
        var total: Int
        /// İndirilen şarkının adı
        var title: String
        /// Genel ilerleme 0...1
        var progress: Double
        var finished: Bool
        /// İndirilemeyen şarkı sayısı
        var failed: Int
        /// Yerelleştirilmiş durum metni ("İndiriliyor", "Tamamlandı")
        var status: String
    }

    var name: String
}
