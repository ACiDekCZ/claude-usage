import Foundation
import Security
import CommonCrypto
import SQLite3
import os

private func chromeLog(_ message: String) {
    Logger(subsystem: "cz.visek.milan.ClaudeUsage", category: "cookies")
        .notice("\(message, privacy: .public)")
    let path = "/tmp/claude-usage-debug.log"
    let line = "\(Date()): [cookies] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

struct ChromeCookie {
    let name: String
    let value: String
    let hostKey: String
    let path: String
    let isSecure: Bool
    let expiresUtc: Int64  // Chrome WebKit epoch microseconds
}

enum ChromeImportError: Error, LocalizedError {
    case chromeNotInstalled
    case keychainAccessDenied
    case cookiesDbUnreadable(String)
    case sessionCookieNotFound
    case decryptFailed(String)
    case unsupportedEncryption(String)  // e.g. v20 App-Bound Encryption

    var errorDescription: String? {
        switch self {
        case .chromeNotInstalled: return "Chrome not installed"
        case .keychainAccessDenied: return "Keychain access denied (need 'Chrome Safe Storage')"
        case .cookiesDbUnreadable(let s): return "Cookies DB error: \(s)"
        case .sessionCookieNotFound: return "Not logged into claude.ai in Chrome"
        case .decryptFailed(let s): return "Cookie decryption failed: \(s)"
        case .unsupportedEncryption(let s): return "Unsupported cookie encryption (\(s))"
        }
    }
}

enum ChromeCookieImporter {

    static func importClaudeCookies() throws -> [ChromeCookie] {
        let key = try getEncryptionKey()
        let profiles = chromeProfiles()
        guard !profiles.isEmpty else { throw ChromeImportError.chromeNotInstalled }

        var lastError: Error?
        for profile in profiles {
            do {
                let cookies = try readCookies(from: profile, key: key)
                if cookies.contains(where: { $0.name == "sessionKey" }) {
                    return cookies
                }
            } catch {
                lastError = error
            }
        }
        if let e = lastError { throw e }
        throw ChromeImportError.sessionCookieNotFound
    }

    // MARK: - Profile discovery

    private static func chromeProfiles() -> [URL] {
        let chromeRoot = NSString("~/Library/Application Support/Google/Chrome").expandingTildeInPath
        let rootURL = URL(fileURLWithPath: chromeRoot)
        let candidates = ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4", "Profile 5"]
        return candidates
            .map { rootURL.appendingPathComponent($0).appendingPathComponent("Cookies") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Keychain key

    private static func getEncryptionKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let passData = result as? Data,
              let password = String(data: passData, encoding: .utf8) else {
            chromeLog("Keychain access failed (status=\(status))")
            throw ChromeImportError.keychainAccessDenied
        }
        return try pbkdf2(password: password, salt: "saltysalt", iterations: 1003, keyLength: 16)
    }

    private static func pbkdf2(password: String, salt: String, iterations: Int, keyLength: Int) throws -> Data {
        guard let passData = password.data(using: .utf8) else {
            throw ChromeImportError.keychainAccessDenied
        }
        let saltBytes = Array(salt.utf8)
        var derived = Data(count: keyLength)

        let status = derived.withUnsafeMutableBytes { (derivedPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            passData.withUnsafeBytes { (passPtr: UnsafeRawBufferPointer) -> Int32 in
                let passBase = passPtr.bindMemory(to: Int8.self).baseAddress
                let derivedBase = derivedPtr.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passBase, passData.count,
                    saltBytes, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(iterations),
                    derivedBase, keyLength
                )
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw ChromeImportError.decryptFailed("PBKDF2 status \(status)")
        }
        return derived
    }

    // MARK: - SQLite read

    private static func readCookies(from cookiesURL: URL, key: Data) throws -> [ChromeCookie] {
        // Copy to temp because Chrome may hold an exclusive lock on WAL pages
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-usage-cookies-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try FileManager.default.copyItem(at: cookiesURL, to: tmp)
        } catch {
            throw ChromeImportError.cookiesDbUnreadable("copy: \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(tmp.path, &db, openFlags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ChromeImportError.cookiesDbUnreadable(msg)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT host_key, name, encrypted_value, path, is_secure, expires_utc
            FROM cookies
            WHERE host_key LIKE '%claude.ai%' OR host_key LIKE '%claude.com%'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ChromeImportError.cookiesDbUnreadable("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = SQLITE_TRANSIENT  // silence unused

        var results: [ChromeCookie] = []
        var rowCount = 0
        var skipped = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowCount += 1
            let hostKey = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let blobLen = sqlite3_column_bytes(stmt, 2)
            guard blobLen > 0, let blobPtr = sqlite3_column_blob(stmt, 2) else {
                chromeLog("row \(rowCount) \(name)@\(hostKey) has no encrypted_value")
                skipped += 1
                continue
            }
            let encryptedData = Data(bytes: blobPtr, count: Int(blobLen))

            let path = String(cString: sqlite3_column_text(stmt, 3))
            let isSecure = sqlite3_column_int(stmt, 4) != 0
            let expiresUtc = sqlite3_column_int64(stmt, 5)

            do {
                let value = try decrypt(encryptedData, key: key)
                results.append(ChromeCookie(
                    name: name,
                    value: value,
                    hostKey: hostKey,
                    path: path,
                    isSecure: isSecure,
                    expiresUtc: expiresUtc
                ))
            } catch {
                skipped += 1
                let prefixHex = encryptedData.prefix(3).map { String(format: "%02x", $0) }.joined()
                chromeLog("skipped \(name)@\(hostKey) (len=\(encryptedData.count), prefix=\(prefixHex)): \(error)")
            }
        }
        let profile = cookiesURL.deletingLastPathComponent().lastPathComponent
        chromeLog("readCookies from \(profile): \(rowCount) rows, \(results.count) decrypted, \(skipped) skipped")
        return results
    }

    // MARK: - AES-CBC decryption

    private static func decrypt(_ blob: Data, key: Data) throws -> String {
        guard blob.count > 3 else {
            throw ChromeImportError.decryptFailed("too short")
        }
        let prefix = String(data: blob.prefix(3), encoding: .ascii) ?? ""
        let ciphertext: Data
        switch prefix {
        case "v10", "v11":
            ciphertext = blob.subdata(in: 3..<blob.count)
        case "v20":
            throw ChromeImportError.unsupportedEncryption("v20 (App-Bound)")
        default:
            ciphertext = blob
        }

        // IV is 16 ASCII spaces (0x20)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var outBuf = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen = 0

        let status = key.withUnsafeBytes { (keyPtr: UnsafeRawBufferPointer) -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { (ctPtr: UnsafeRawBufferPointer) -> CCCryptorStatus in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyPtr.baseAddress, key.count,
                    iv,
                    ctPtr.baseAddress, ciphertext.count,
                    &outBuf, outBuf.count,
                    &outLen
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw ChromeImportError.decryptFailed("CCCrypt status \(status)")
        }
        let plain = Array(outBuf.prefix(outLen))
        // Chrome 88+ on macOS prepends a 32-byte SHA-256 of the host key to the cookie value.
        // Try parsing as UTF-8 first; if that fails, strip the 32-byte hash prefix and retry.
        if let s = String(bytes: plain, encoding: .utf8) { return s }
        if plain.count >= 32, let s = String(bytes: plain.dropFirst(32), encoding: .utf8) { return s }
        throw ChromeImportError.decryptFailed("not utf8")
    }
}
