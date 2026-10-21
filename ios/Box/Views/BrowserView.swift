import SwiftUI
import WebKit

// MARK: - Model

/// Tarayıcı sekmesinde süren bir indirme.
struct BrowserDownload: Identifiable, Equatable {
    let id: ObjectIdentifier
    let name: String
    var progress: Double
}

/// Uygulama içi tarayıcı: tek WKWebView, indirilen dosyalar doğrudan Box'a.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView

    @Published var address = ""
    @Published private(set) var host = ""
    @Published private(set) var isSecure = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var showingPage = false
    @Published private(set) var downloads: [BrowserDownload] = []

    /// İndirme bitince (geçici dosya). Dosyayı Box'a taşıma işi görünümde.
    var onFinished: ((URL, String) async -> Void)?
    var onFailed: ((String) -> Void)?
    /// Dosya indirme Premium'a özel: izin yoksa indirme başlamaz, onBlocked çağrılır.
    var canDownload: () -> Bool = { false }
    var onBlocked: (() -> Void)?

    private var observers: [NSKeyValueObservation] = []
    private var progressObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var destinations: [ObjectIdentifier: (url: URL, name: String)] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        observers = [
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.url) { [weak self] view, _ in
                Task { @MainActor in self?.updateAddress(view.url) }
            },
        ]
    }

    /// Adres, alan adı ya da arama metni.
    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = Self.url(for: text) else { return }
        showingPage = true
        webView.load(URLRequest(url: url))
    }

    static func url(for text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return URL(string: text) }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil { return url }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    func goHome() {
        webView.stopLoading()
        showingPage = false
        address = ""
    }

    func back() { if webView.canGoBack { webView.goBack() } else { goHome() } }
    func forward() { webView.goForward() }
    func reloadOrStop() { if isLoading { webView.stopLoading() } else { webView.reload() } }

    private func updateAddress(_ url: URL?) {
        guard let url else { return }
        host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        isSecure = url.scheme == "https"
        address = url.absoluteString
    }

    // MARK: Gezinme

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            if canDownload() { decisionHandler(.download) } else { decisionHandler(.cancel); onBlocked?() }
            return
        }
        // App Store, telefon gibi bağlantılar sistemde açılsın.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = (navigationResponse.response.mimeType ?? "").lowercased()
        var attachment = false
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("attachment") {
            attachment = true
        }
        let isFile = mime.hasPrefix("audio/") || mime == "application/octet-stream" || mime == "application/zip"
        if navigationResponse.isForMainFrame && (attachment || isFile || !navigationResponse.canShowMIMEType) {
            if canDownload() { decisionHandler(.download) } else { decisionHandler(.cancel); onBlocked?() }
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Yeni pencere isteyen bağlantılar aynı sayfada açılır.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: İndirme

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let name = Self.cleanName(suggestedFilename)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        let id = ObjectIdentifier(download)
        destinations[id] = (destination, name)
        downloads.append(BrowserDownload(id: id, name: name, progress: 0))
        progressObservers[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                guard let self, let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                self.downloads[index].progress = value
            }
        }
        Haptics.tap()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        finish(id)
        guard let target = destinations.removeValue(forKey: id) else { return }
        Task {
            await onFinished?(target.url, target.name)
            try? FileManager.default.removeItem(at: target.url.deletingLastPathComponent())
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        finish(id)
        if let target = destinations.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: target.url.deletingLastPathComponent())
            onFailed?(target.name)
        }
    }

    private func finish(_ id: ObjectIdentifier) {
        progressObservers[id] = nil
        downloads.removeAll { $0.id == id }
    }

    static func cleanName(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "indirilen-dosya" : String(cleaned.prefix(120))
    }
}

// MARK: - Görünüm

struct BrowserView: View {
    @EnvironmentObject private var server: ServerState
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var model = BrowserModel()
    @FocusState private var editing: Bool

    private var shortcuts: [BrowserShortcut] {
        var list = [
            BrowserShortcut(title: "YouTube", url: "https://m.youtube.com"),
            BrowserShortcut(title: "YouTube Music", url: "https://music.youtube.com"),
            BrowserShortcut(title: "Google", url: "https://www.google.com"),
        ]
        for item in server.browserShortcuts where !list.contains(where: { $0.url == item.url }) { list.append(item) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                WebViewHost(webView: model.webView)
                    .opacity(model.showingPage ? 1 : 0)
                    .allowsHitTesting(model.showingPage)
                if !model.showingPage { startPage }
                if model.isLoading && model.showingPage {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accent)
                            .frame(width: geo.size.width * max(0.06, model.progress), height: 2)
                            .animation(.easeOut(duration: 0.2), value: model.progress)
                    }
                    .frame(height: 2)
                }
            }
            if !model.downloads.isEmpty { downloadStrip }
        }
        .boxScreenBackground()
        .onAppear {
            model.onFinished = { url, name in await save(url, name: name) }
            model.onFailed = { name in router.show(L("İndirilemedi: {0}", name), icon: "exclamationmark.triangle.fill") }
            model.canDownload = { [weak auth] in auth?.has(.browser) == true }
            model.onBlocked = { [weak auth, weak router] in
                if auth?.isPremium == true {
                    router?.show(L("Tarayıcıdan indirme hesabında kapalı."), icon: "lock.fill")
                } else {
                    router?.showPremium = true
                }
            }
        }
    }

    // MARK: Adres çubuğu

    private var addressBar: some View {
        HStack(spacing: 10) {
            if model.showingPage {
                barButton("chevron.left", label: L("Geri")) { model.back() }
                barButton("chevron.right", label: L("İleri")) { model.forward() }
                    .disabled(!model.canGoForward)
                    .opacity(model.canGoForward ? 1 : 0.35)
            }
            HStack(spacing: 8) {
                Image(systemName: model.showingPage && !editing ? (model.isSecure ? "lock.fill" : "globe") : "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.boxSecondaryText)
                TextField(L("Ara ya da adres yaz"), text: $model.address)
                    .focused($editing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .onSubmit { model.open(model.address) }
                    .overlay(alignment: .leading) {
                        // Düzenlenmiyorken yalnızca alan adı görünsün.
                        if model.showingPage && !editing && !model.host.isEmpty {
                            Text(model.host)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.boxSurface2)
                                .allowsHitTesting(false)
                        }
                    }
                if editing && !model.address.isEmpty {
                    Button { model.address = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.boxTertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Capsule().fill(Color.boxSurface2))
            if model.showingPage {
                barButton(model.isLoading ? "xmark" : "arrow.clockwise", label: model.isLoading ? L("Durdur") : L("Yenile")) { model.reloadOrStop() }
                barButton("house", label: L("Başlangıç")) { model.goHome() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func barButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .accessibilityLabel(label)
    }

    // MARK: Başlangıç sayfası

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L("Tarayıcı"))
                    .font(.system(size: 30, weight: .heavy))
                    .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(shortcuts) { item in
                        Button { model.open(item.url) } label: { ShortcutTile(item: item) }
                            .buttonStyle(PressableStyle())
                    }
                }
                if !auth.has(.browser) {
                    Button { router.showPremium = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.accent))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Dosya indirme Premium'a özel"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(L("Gezinmek serbest; indirdiklerini Box'a eklemek için Premium'a geç."))
                                    .font(.system(size: 13))
                                    .foregroundColor(.boxSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(.boxTertiaryText)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accent.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.accent)
                    Text(L("Tarayıcıdan indirdiğin ses dosyaları Dosyalar › {0} klasörüne kaydedilir ve kitaplığına eklenir.", AppConfig.browserFolderName))
                        .font(.system(size: 14))
                        .foregroundColor(.boxSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.boxSurface))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: İndirmeler

    private var downloadStrip: some View {
        VStack(spacing: 8) {
            ForEach(model.downloads) { item in
                HStack(spacing: 12) {
                    DownloadFillIcon(progress: item.progress > 0 ? item.progress : nil, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(L("İndiriliyor • %{0}", Int(item.progress * 100)))
                            .font(.system(size: 12))
                            .foregroundColor(.boxSecondaryText)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.boxSurface)
    }

    private func save(_ url: URL, name: String) async {
        let folder = library.documents.appendingPathComponent(AppConfig.browserFolderName, isDirectory: true)
        let count = await library.importFiles([url], into: folder)
        if count > 0 {
            Haptics.success()
            router.show(L("Box'a eklendi: {0}", name), icon: "checkmark.circle.fill")
        } else {
            router.show(L("İndirilemedi: {0}", name), icon: "exclamationmark.triangle.fill")
        }
    }
}

private struct ShortcutTile: View {
    let item: BrowserShortcut

    private var host: String { URL(string: item.url)?.host?.lowercased() ?? "" }

    private var style: (icon: String, color: Color) {
        if host.contains("music.youtube") { return ("music.note", Color(red: 1, green: 0.2, blue: 0.25)) }
        if host.contains("youtube") || host.contains("youtu.be") { return ("play.rectangle.fill", Color(red: 1, green: 0.16, blue: 0.16)) }
        if host.contains("google") { return ("magnifyingglass", Color(red: 0.26, green: 0.52, blue: 0.96)) }
        return ("globe", .accent)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(host.replacingOccurrences(of: "www.", with: ""))
                    .font(.system(size: 12))
                    .foregroundColor(.boxTertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.boxSurface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.boxStroke, lineWidth: 1))
    }
}

private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
