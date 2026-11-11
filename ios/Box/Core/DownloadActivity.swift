import ActivityKit
import Combine
import Foundation

/// Toplu indirmeyi kilit ekranında ve Dynamic Island'da gösterir (iOS 16.1+).
/// Yalnızca 2+ şarkı birlikte indirilirken açılır. Güncellemeler uygulama çalıştığı sürece gönderilir.
@MainActor
final class DownloadActivityController {
    private var activity: Any?
    private var batch: Set<String> = []
    private var lastPush = Date.distantPast
    private var endTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    func bind(to manager: DownloadManager) {
        bag.removeAll()
        manager.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak manager] items in
                guard let self, let manager else { return }
                self.update(items: items, manager: manager)
            }
            .store(in: &bag)
    }

    private func update(items: [String: DownloadItem], manager: DownloadManager) {
        guard #available(iOS 16.1, *) else { return }
        let active = items.values.filter { $0.state.isActive }
        for item in active { batch.insert(item.id) }
        if activity == nil {
            guard active.count >= 2, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            endTask?.cancel()
            start(state: makeState(items: items, active: active, finished: false))
            return
        }
        let finished = active.isEmpty
        // Sık güncellemeyi kıs (1 sn), bitişi hemen gönder.
        guard finished || Date().timeIntervalSince(lastPush) > 1 else { return }
        push(makeState(items: items, active: active, finished: finished), end: finished)
    }

    @available(iOS 16.1, *)
    private func makeState(items: [String: DownloadItem], active: [DownloadItem], finished: Bool) -> DownloadActivityAttributes.ContentState {
        var done = 0
        var failed = 0
        var partial = 0.0
        for id in batch {
            guard let item = items[id] else { done += 1; continue }
            switch item.state {
            case .done: done += 1
            case .failed: done += 1; failed += 1
            case .downloading(let p): partial += p
            case .processing: partial += 0.95
            case .preparing: break
            }
        }
        let total = max(batch.count, 1)
        let progress = finished ? 1 : min(1, (Double(done) + partial) / Double(total))
        let current = active.first { if case .downloading = $0.state { return true } else { return false } } ?? active.first
        return .init(
            done: done,
            total: total,
            title: finished ? "" : (current?.title ?? ""),
            progress: progress,
            finished: finished,
            failed: failed,
            status: finished ? L("İndirme tamamlandı") : L("İndiriliyor")
        )
    }

    @available(iOS 16.1, *)
    private func start(state: DownloadActivityAttributes.ContentState) {
        do {
            activity = try Activity.request(
                attributes: DownloadActivityAttributes(name: "downloads"),
                contentState: state,
                pushType: nil
            )
            lastPush = Date()
        } catch {
            activity = nil
        }
    }

    @available(iOS 16.1, *)
    private func push(_ state: DownloadActivityAttributes.ContentState, end: Bool) {
        guard let live = activity as? Activity<DownloadActivityAttributes> else { activity = nil; return }
        lastPush = Date()
        if end {
            activity = nil
            batch.removeAll()
            Task { await live.end(using: state, dismissalPolicy: .after(Date().addingTimeInterval(6))) }
        } else {
            Task { await live.update(using: state) }
        }
    }
}
