import SwiftUI
import UIKit

/// Box'a özel onay penceresi. Sistem diyaloğu yerine her şeyin (alt panel, sayfalar) üstünde
/// ortada açılan bir kart: ikon, başlık, açıklama, büyük onay ve vazgeç butonları.
struct ConfirmRequest {
    var icon: String
    var title: String
    var message: String?
    var confirmTitle: String?
    var destructive: Bool
    var action: () -> Void
}

@MainActor
final class ConfirmPresenter: ObservableObject {
    static let shared = ConfirmPresenter()

    @Published fileprivate(set) var request: ConfirmRequest?
    @Published fileprivate(set) var visible = false
    private var window: UIWindow?
    private var onDismiss: (() -> Void)?

    func show(_ request: ConfirmRequest, onDismiss: @escaping () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            onDismiss()
            return
        }
        // Açık bir onay varsa sessizce kapat.
        self.onDismiss?()
        self.request = request
        self.onDismiss = onDismiss

        if window == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: ConfirmHost(presenter: self)
                .environment(\.layoutDirection, Lang.shared.layoutDirection)
                .environment(\.locale, Lang.shared.locale))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.makeKeyAndVisible()
            self.window = window
        }
        UINotificationFeedbackGenerator().notificationOccurred(request.destructive ? .warning : .success)
        DispatchQueue.main.async { self.visible = true }
    }

    func dismiss(confirmed: Bool) {
        guard visible else { return }
        let action = confirmed ? request?.action : nil
        visible = false
        action?()
        let done = onDismiss
        onDismiss = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            done?()
            guard !self.visible else { return }
            self.request = nil
            self.window?.isHidden = true
            self.window = nil
        }
    }
}

private struct ConfirmHost: View {
    @ObservedObject var presenter: ConfirmPresenter

    var body: some View {
        ZStack {
            if presenter.visible {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { presenter.dismiss(confirmed: false) }
                    .transition(.opacity)
            }
            if presenter.visible, let request = presenter.request {
                ConfirmCard(request: request) { presenter.dismiss(confirmed: $0) }
                    .padding(.horizontal, 28)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: presenter.visible)
    }
}

private struct ConfirmCard: View {
    let request: ConfirmRequest
    let finish: (Bool) -> Void

    private static let danger = Color(red: 1.0, green: 0.36, blue: 0.38)
    private var tint: Color { request.destructive ? Self.danger : .accent }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 64, height: 64)
                Circle().strokeBorder(tint.opacity(0.28), lineWidth: 1).frame(width: 64, height: 64)
                Image(systemName: request.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(tint)
            }
            .padding(.bottom, 16)

            Text(request.title)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let message = request.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.boxSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            VStack(spacing: 10) {
                if let confirm = request.confirmTitle {
                    Button { finish(true) } label: {
                        Text(confirm)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .foregroundColor(request.destructive ? .white : .black)
                            .background(Capsule().fill(tint))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
                Button { finish(false) } label: {
                    Text(L("Vazgeç"))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(PressableStyle(scale: 0.97))
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.boxSurface2)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.boxStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct BoxConfirmModifier: ViewModifier {
    @Binding var isPresented: Bool
    let request: ConfirmRequest

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { shown in
            guard shown else { return }
            ConfirmPresenter.shared.show(request) { isPresented = false }
        }
    }
}

extension View {
    /// Box tarzı onay penceresi. `confirmTitle` nil ise yalnızca "Vazgeç" görünür.
    func boxConfirm(
        _ title: String,
        isPresented: Binding<Bool>,
        icon: String,
        message: String? = nil,
        confirmTitle: String?,
        destructive: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        modifier(BoxConfirmModifier(
            isPresented: isPresented,
            request: ConfirmRequest(icon: icon, title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, action: action)
        ))
    }
}
