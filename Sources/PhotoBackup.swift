import Photos
import Foundation

/// 照片备份：读取相册照片并逐张上传
enum PhotoBackup {

    /// 备份相册中的照片
    /// - Parameters:
    ///   - limit: 备份张数上限（0 = 全部）
    ///   - uploader: 上传服务
    ///   - progress: 进度回调（当前第几张 / 总数 / 说明文字）
    /// - Returns: 成功上传的张数
    static func backupAssets(limit: Int,
                             uploader: UploadService,
                             progress: @escaping (Int, Int, String) -> Void) async throws -> Int {
        // 1. 检查/申请相册权限
        let authorized = try await requestAuthorization()
        guard authorized else {
            throw BackupError.message("没有允许访问照片。请到 设置 → 隐私与安全性 → 照片 打开权限后再试。")
        }

        // 2. 按时间倒序取出照片
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if limit > 0 {
            options.fetchLimit = limit
        }
        let fetch = PHAsset.fetchAssets(with: .image, options: options)

        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        guard !assets.isEmpty else {
            throw BackupError.message("相册里没有照片。")
        }

        // 3. 逐张读取并上传
        let total = assets.count
        var uploaded = 0
        for (index, asset) in assets.enumerated() {
            progress(index + 1, total, "正在读取第 \(index + 1)/\(total) 张")
            let data = try await imageData(for: asset)
            let ext = fileExtension(for: data)
            let filename = String(format: "IMG_%04d.%@", index + 1, ext)
            _ = try await uploader.upload(data: data, filename: filename, category: "photos")
            uploaded += 1
            progress(index + 1, total, "已上传 \(uploaded) 张")
        }
        return uploaded
    }

    // MARK: - 私有方法

    private static func requestAuthorization() async throws -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return try await withCheckedThrowingContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    cont.resume(returning: (newStatus == .authorized || newStatus == .limited))
                }
            }
        default:
            return false
        }
    }

    private static func imageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset,
                                                                    options: options) { data, _, _, _ in
                if let data = data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: BackupError.message("读取照片数据失败"))
                }
            }
        }
    }

    /// 根据文件头判断扩展名（.jpg / .heic / .png）
    private static func fileExtension(for data: Data) -> String {
        if data.count > 2, data[0] == 0xFF, data[1] == 0xD8 { return "jpg" }        // JPEG
        if data.count > 8, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return "png" } // PNG
        if data.count > 12, data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 { return "heic" } // ftyp
        return "jpg"
    }
}
