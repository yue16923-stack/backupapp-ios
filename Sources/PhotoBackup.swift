import Photos
import UIKit
import CryptoKit
import Foundation

/// 照片备份：和安卓版一致
/// 全部照片按时间正序扫描 → 压缩（最长边 1280、JPEG 质量 70%）→ 断点续传 + MD5 去重 → multipart 上传
enum PhotoBackup {

    struct Result {
        let uploaded: Int
        let skipped: Int
        let md5Set: Set<String>
        let lastUploadedID: String?
    }

    static func backupAllPhotos(uploader: UploadService,
                                knownMd5: Set<String>,
                                lastUploadedID: String?,
                                progress: @escaping (Int, Int, String, String?) -> Void) async throws -> Result {
        // 1. 权限
        let authorized = try await requestAuthorization()
        guard authorized else {
            throw BackupError.message("没有允许访问照片，请到 设置→隐私与安全性→照片 打开权限")
        }

        // 2. 取全部照片 + 隐藏相簿（时间正序，对应安卓 _ID ASC）
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var assets: [PHAsset] = []
        var seen = Set<String>()

        func collect(_ fetch: PHFetchResult<PHAsset>) {
            fetch.enumerateObjects { asset, _, _ in
                if seen.insert(asset.localIdentifier).inserted {
                    assets.append(asset)
                }
            }
        }
        collect(PHAsset.fetchAssets(with: .image, options: options))
        // 隐藏相簿（完全访问权限下可读）
        if let hiddenAlbum = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                     subtype: .smartAlbumAllHidden,
                                                                     options: nil).firstObject {
            collect(PHAsset.fetchAssets(in: hiddenAlbum, options: options))
        }
        guard !assets.isEmpty else {
            throw BackupError.message("相册里没有照片")
        }

        // 3. 断点续传：按时间+ID 排序，从上次停下的位置继续，前面的完全不碰
        let sorted = assets.sorted { a, b in
            let da = a.creationDate ?? .distantPast
            let db = b.creationDate ?? .distantPast
            if da == db {
                return a.localIdentifier < b.localIdentifier
            }
            return da < db
        }
        var startIndex = 0
        if let lastID = lastUploadedID,
           let idx = sorted.firstIndex(where: { $0.localIdentifier == lastID }) {
            startIndex = idx + 1
        }

        var localSet = knownMd5
        var uploaded = 0
        var skipped = 0
        var lastUploaded: String? = lastUploadedID
        let total = sorted.count

        for index in startIndex..<total {
            let asset = sorted[index]
            progress(index + 1, total, "正在处理第 \(index + 1)/\(total) 张", nil)
            do {
                guard let jpeg = try await compressedJpeg(for: asset) else {
                    skipped += 1
                    continue
                }
                let md5 = calcMD5(jpeg)
                if md5.isEmpty || localSet.contains(md5) {
                    skipped += 1
                    continue
                }
                // 拍摄时间（毫秒时间戳），服务器拼进文件名 _taken_<时间戳>，和安卓版一致
                let takenMs = asset.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
                try await uploader.uploadPhoto(jpeg: jpeg, md5: md5, takenMs: takenMs)
                localSet.insert(md5)
                lastUploaded = asset.localIdentifier
                uploaded += 1
                // 每成功一张立刻把断点回调出去，调用方实时保存，中途退出也不丢
                progress(index + 1, total, "已上传 \(uploaded) 张（跳过已上传 \(skipped) 张）", asset.localIdentifier)
                try? await Task.sleep(nanoseconds: 150_000_000) // 每张间隔 0.15 秒
            } catch {
                progress(index + 1, total, "第 \(index + 1) 张失败：\(error.localizedDescription)", nil)
            }
        }
        return Result(uploaded: uploaded, skipped: skipped, md5Set: localSet, lastUploadedID: lastUploaded)
    }

    // MARK: - 私有方法

    private static func requestAuthorization() async throws -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
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

    /// 压缩：最长边 1280，JPEG 质量 70%（清晰够用、体积小、上传快）
    private static func compressedJpeg(for asset: PHAsset) async throws -> Data? {
        let data = try await imageData(for: asset)
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1280
        let w = img.size.width
        let h = img.size.height
        guard w > 0, h > 0 else { return nil }
        let longest = max(w, h)
        var scale: CGFloat = 1
        if longest > maxSide {
            scale = maxSide / longest
        }
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    /// 计算 MD5（和安卓 MessageDigest 一致的小写十六进制）
    private static func calcMD5(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
