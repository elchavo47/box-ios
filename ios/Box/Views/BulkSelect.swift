import SwiftUI

/// Toplu seçim: satırın başında seçim işareti gösterir, seçim modundayken satırın kendi düğmelerini devre dışı bırakır.
struct SelectableRow<Content: View>: View {
    let selecting: Bool
    let isSelected: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .accent : .boxSecondaryText)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content().allowsHitTesting(!selecting)
        }
        .contentShape(Rectangle())
    }
}

/// Alt çubuk: kaç şarkı seçili, "Hepsini seç" ve eylem düğmeleri.
struct BulkBar<Actions: View>: View {
    let count: Int
    let total: Int
    let onToggleAll: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(count == 0 ? L("Şarkı seç") : L("{0} seçili", count))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(count == total && total > 0 ? L("Seçimi kaldır") : L("Hepsini seç"), action: onToggleAll)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accent)
            }
            HStack(spacing: 10) { actions() }
                .disabled(count == 0)
                .opacity(count == 0 ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }
}

/// Çubuktaki eylem düğmesinin görünümü.
struct BulkActionLabel: View {
    let title: String
    let icon: String
    var destructive = false

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(destructive ? .red : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }
}

/// Seçilen şarkıları var olan ya da yeni bir listeye ekler.
struct BulkAddToPlaylist: View {
    let tracks: [Track]
    let onDone: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: AppRouter
    @State private var showNew = false
    @State private var name = ""

    var body: some View {
        Menu {
            Button { showNew = true } label: { Label(L("Yeni liste…"), systemImage: "plus") }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { playlist in
                Button(playlist.name) {
                    library.add(tracks, to: playlist.id)
                    Haptics.success()
                    router.show(L("{0} şarkı {1} listesine eklendi", tracks.count, playlist.name), icon: "text.badge.plus")
                    onDone()
                }
            }
        } label: {
            BulkActionLabel(title: L("Listeye ekle"), icon: "text.badge.plus")
        }
        .alert(L("Yeni çalma listesi"), isPresented: $showNew) {
            TextField(L("Liste adı"), text: $name)
            Button(L("Oluştur")) {
                let list = library.createPlaylist(name: name.trimmingCharacters(in: .whitespaces), tracks: tracks)
                name = ""
                Haptics.success()
                router.show(L("{0} şarkı {1} listesine eklendi", tracks.count, list.name), icon: "text.badge.plus")
                onDone()
            }
            Button(L("Vazgeç"), role: .cancel) { name = "" }
        }
    }
}
