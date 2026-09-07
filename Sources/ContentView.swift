import SwiftUI

struct ContentView: View {
    @State private var serverURL = "https://omgga-entertainment-server.hf.space"
    @State private var key = ""
    @State private var photoCount = 50
    @State private var isBusy = false
    @State private var log = "准备就绪。\n"
    @State private var task: Task<Void, Never>?

    private var uploader: UploadService {
        UploadService(serverURL: serverURL, key: key)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器设置")) {
                    TextField("服务器地址", text: $serverURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("访问口令（可选，和服务器 BACKUP_KEY 一致）", text: $key)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Picker("备份照片数量", selection: $photoCount) {
                        Text("最近 50 张").tag(50)
                        Text("最近 100 张").tag(100)
                        Text("最近 200 张").tag(200)
                        Text("最近 500 张").tag(500)
                        Text("全部照片（很慢）").tag(0)
                    }
                }

                Section {
                    Button(action: { runContacts() }) {
                        Label("备份通讯录", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(isBusy)

                    Button(action: { runPhotos() }) {
                        Label("备份照片", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(isBusy)
                }

                if isBusy {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在备份，请保持 App 在前台…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("备份日志")) {
                    ScrollView {
                        Text(log)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                }
            }
            .navigationTitle("通讯录照片备份")
            .onDisappear {
                task?.cancel()
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 动作

    private func runContacts() {
        guard !isBusy else { return }
        isBusy = true
        appendLog("开始备份通讯录…")
        task = Task {
            do {
                let data = try await ContactBackup.exportVCard()
                let filename = "通讯录备份_\(Self.dateString()).vcf"
                appendLog("联系人数据 \(data.count) 字节，正在上传…")
                let resp = try await uploader.upload(data: data, filename: filename, category: "contacts")
                appendLog("✅ 通讯录备份成功：\(filename)")
                appendLog("服务器返回：\(resp)")
            } catch {
                appendLog("❌ 失败：\(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    private func runPhotos() {
        guard !isBusy else { return }
        isBusy = true
        if photoCount == 0 {
            appendLog("开始备份全部照片（可能很慢，建议分批）…")
        } else {
            appendLog("开始备份最近 \(photoCount) 张照片…")
        }
        let count = photoCount
        let up = uploader
        task = Task {
            do {
                let uploaded = try await PhotoBackup.backupAssets(limit: count, uploader: up) { done, total, msg in
                    if done == 1 || done == total || done % 10 == 0 {
                        appendLog("\(msg)")
                    }
                }
                appendLog("✅ 照片备份完成，共 \(uploaded) 张")
            } catch {
                appendLog("❌ 失败：\(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text + "\n"
        }
    }

    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
