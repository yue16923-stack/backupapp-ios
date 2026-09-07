import Contacts
import Foundation

/// 通讯录备份：和安卓版一致，每个号码一条 {"name": ..., "phone": ...}
enum ContactBackup {

    static func exportContacts() async throws -> [[String: String]] {
        let store = CNContactStore()

        // 1. 检查 / 申请通讯录权限
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = try await requestAccess(store)
            if !granted {
                throw BackupError.message("没有允许访问通讯录，请到 设置→隐私与安全性→通讯录 打开权限")
            }
        case .denied:
            throw BackupError.message("没有允许访问通讯录，请到 设置→隐私与安全性→通讯录 打开权限")
        case .restricted:
            throw BackupError.message("通讯录访问受限")
        @unknown default:
            throw BackupError.message("通讯录访问受限")
        }

        // 2. 读取联系人（姓名 + 全部号码）
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var result: [[String: String]] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = (contact.familyName + contact.givenName).trimmingCharacters(in: .whitespaces)
            for phone in contact.phoneNumbers {
                var item: [String: String] = [:]
                item["name"] = name.isEmpty ? "(未命名)" : name
                item["phone"] = phone.value.stringValue
                result.append(item)
            }
        }
        return result
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
