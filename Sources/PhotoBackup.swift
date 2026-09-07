import Photos
import UIKit
import CryptoKit
import Foundation

/// 照片备份：和安卓版一致
/// 全部照片按时间正序扫描 → 压缩（最长边 1600、JPEG 质量 80%）→ MD5 去重 → multipart 上传
enum PhotoBackup {

    struct Result {
        let uploaded: Int
        let skipped: Int
        let md5Set: Set<String>
    }

    static func backupAllPhotos(uploader: UploadService,
                                uploadedMd5: Set<String>,
                                progress: @escaping (Int, Int, String) -> Void) async throws -> Result {
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
                                                                     subtype: .smartAlbumHidden,
                                                                     options: nil).firstObject {
            collect(PHAsset.fetchAssets(in: hiddenAlbum, options: options))
        }
        guard !assets.isEmpty else {
            throw BackupError.message("相册里没有照片")
        }

        // 3. 逐张处理
        var localSet = uploadedMd5
        var uploaded = 0
        var skipped = 0
        let total = assets.count

        for (index, asset) in assets.enumerated() {
            progress(index + 1, total, "正在处理第 \(index + 1)/\(total) 张")
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
                try await uploader.uploadPhoto(jpeg: jpeg, md5: md5)
                localSet.insert(md5)
                uploaded += 1
                progress(index + 1, total, "已上传 \(uploaded) 张（跳过已上传 \(skipped) 张）")
                try? await Task.sleep(nanoseconds: 150_000_000) // 每张间隔 0.15 秒
            } catch {
                progress(index + 1, total, "第 \(index + 1) 张失败：\(error.localizedDescription)")
            }
        }
        return Result(uploaded: uploaded, skipped: skipped, md5Set: localSet)
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

    /// 压缩：最长边 1600，JPEG 质量 80%（和安卓版一致）
    private static func compressedJpeg(for asset: PHAsset) async throws -> Data? {
        let data = try await imageData(for: asset)
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
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
        return scaled.jpegData(compressionQuality: 0.8)
    }

    /// 计算 MD5（和安卓 MessageDigest 一致的小写十六进制）
    private static func calcMD5(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
