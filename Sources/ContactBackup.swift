import Contacts
import Foundation

/// 通讯录备份：读取全部联系人并导出成 vCard（.vcf）
enum ContactBackup {

    /// 返回所有联系人的 vCard 数据
    static func exportVCard() async throws -> Data {
        let store = CNContactStore()

        // 1. 检查/申请通讯录权限
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = try await requestAccess(store)
            if !granted {
                throw BackupError.message("没有允许访问通讯录。请到 设置 → 隐私与安全性 → 通讯录 打开权限后再试。")
            }
        case .denied:
            throw BackupError.message("没有允许访问通讯录。请到 设置 → 隐私与安全性 → 通讯录 打开权限后再试。")
        case .restricted:
            throw BackupError.message("通讯录访问受限（可能开启了家长控制/屏幕使用时间）。")
        @unknown default:
            throw BackupError.message("通讯录访问受限。")
        }

        // 2. 读取全部联系人
        let keys: [CNKeyDescriptor] = [CNContactVCardSerialization.descriptorForRequiredKeys()]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }

        guard !contacts.isEmpty else {
            throw BackupError.message("通讯录里没有联系人。")
        }

        // 3. 转成 vCard
        return try CNContactVCardSerialization.data(with: contacts)
    }

    private static func requestAccess(_ store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            store.requestAccess(for: .contacts) { granted, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: granted)
                }
            }
        }
    }
}
