import SwiftUI

struct DeviceEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let os: String?
    let app: String?
    let lastUsedAt: String?
    var lastUsed: Date? { lastUsedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
    let current: Bool
    let legacy: Bool?
}

private struct DevicesResponse: Decodable {
    let devices: [DeviceEntry]
}

/// Hesap › Cihazlarım: oturum açık cihazlar; diğerlerinden tek tek çıkış yapılabilir.
struct DevicesView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var devices: [DeviceEntry] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var confirm: DeviceEntry?
    @State private var confirmOthers = false

    var body: some View {
        List {
            if loading && devices.isEmpty {
                HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                    .listRowBackground(Color.clear)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .listRowBackground(Color.boxSurface2)
            }
            if !devices.isEmpty {
                Section {
                    ForEach(devices) { device in
                        row(device)
                            .swipeActions {
                                if !device.current {
                                    Button(role: .destructive) { confirm = device } label: { Label(L("Çıkış yap"), systemImage: "rectangle.portrait.and.arrow.right") }
                                }
                            }
                    }
                } footer: {
                    Text(L("Tanımadığın bir cihaz görürsen ondan çıkış yap ve şifreni değiştir."))
                }
                .listRowBackground(Color.boxSurface2)

                if devices.count > 1 {
                    Section {
                        Button(role: .destructive) { confirmOthers = true } label: {
                            Label(L("Diğer bütün cihazlardan çıkış yap"), systemImage: "iphone.slash")
                        }
                    }
                    .listRowBackground(Color.boxSurface2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .boxScreenBackground()
        .navigationTitle(L("Cihazlarım"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert(L("{0} cihazından çıkış yapılsın mı?", confirm?.name ?? L("Cihaz")), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(L("Çıkış yap"), role: .destructive) {
                if let device = confirm { Task { await logout(["id": device.id]) } }
            }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .alert(L("Bu cihaz dışındaki bütün cihazlardan çıkış yapılsın mı?"), isPresented: $confirmOthers) {
            Button(L("Hepsinden çıkış yap"), role: .destructive) { Task { await logout(["others": true]) } }
            Button(L("Vazgeç"), role: .cancel) {}
        }
    }

    private func row(_ device: DeviceEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.name.hasPrefix("iPad") ? "ipad" : "iphone")
                .font(.system(size: 22))
                .foregroundColor(device.current ? .accent : .white)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.system(size: 16, weight: .semibold))
                    if device.current {
                        Text(L("Bu cihaz"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accent))
                    }
                }
                Text(details(device))
                    .font(.system(size: 13))
                    .foregroundColor(.boxSecondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func details(_ device: DeviceEntry) -> String {
        var parts: [String] = []
        if let os = device.os { parts.append(os) }
        if let app = device.app { parts.append(L("Box ") + app) }
        if device.current {
            parts.append(L("şu an"))
        } else if let date = device.lastUsed {
            parts.append(Formatters.relative(date))
        }
        return parts.joined(separator: " • ")
    }


    private func load() async {
        guard let token = auth.token else { return }
        loading = true
        defer { loading = false }
        do {
            let response: DevicesResponse = try await APIClient.shared.send("me/devices", token: token)
            devices = response.devices
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Cihazlar yüklenemedi.")
        }
    }

    private func logout(_ body: [String: Any]) async {
        guard let token = auth.token else { return }
        do {
            let response: DevicesResponse = try await APIClient.shared.send("me/devices", method: "POST", body: body, token: token)
            withAnimation { devices = response.devices }
            Haptics.success()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("Çıkış yapılamadı.")
        }
    }
}
