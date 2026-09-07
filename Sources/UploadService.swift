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

/// 负责把数据上传到服务器（和部署手册里的 FastAPI 接口对应）
struct UploadService {
    let serverURL: String
    let key: String

    /// 上传一段数据
    /// - Parameters:
    ///   - data: 要上传的原始数据（内部会转成 base64）
    ///   - filename: 文件名（服务器会自动加时间戳前缀）
    ///   - category: contacts 或 photos
    func upload(data: Data, filename: String, category: String) async throws -> String {
        guard let base = URL(string: serverURL) else {
            throw BackupError.message("服务器地址不正确")
        }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = "/api/backup/\(category)"
        if !key.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "key", value: key)]
        }
        guard let url = comps?.url else {
            throw BackupError.message("服务器地址不正确")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let payload: [String: String] = [
            "filename": filename,
            "data_base64": data.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (respData, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw BackupError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BackupError.message("服务器返回错误：\(text)")
        }
        return String(data: respData, encoding: .utf8) ?? "ok"
    }
}
