import Foundation

/// One Claude subscription the app reads limits for.
///
/// Claude Code keeps everything for a login — the OAuth token in the keychain,
/// `.claude.json`, history — under a config folder, picked by
/// `CLAUDE_CONFIG_DIR`. Each folder that is signed in is therefore an account
/// of its own, and `claude -p /usage` run against it reports that account's
/// limits.
struct ClaudeAccount: Identifiable, Hashable {
    enum Kind {
        /// Claude Code's own `~/.claude`, used when no folder is set.
        case standard
        /// A folder found next to it, such as `~/.claude2` behind an alias.
        case found
        /// A folder the app made itself through Add Account.
        case managed
    }

    let kind: Kind
    /// nil for the standard folder, which is reached by leaving
    /// `CLAUDE_CONFIG_DIR` unset.
    let configDir: URL?
    let email: String?
    /// Set when another folder reports the same address, so the menu can
    /// tell the two apart.
    var showsFolder = false

    var id: String { configDir?.path ?? "default" }

    /// What the menu calls it: the address it is signed in with, or the
    /// folder when there is none.
    var label: String {
        guard let email else { return folderName ?? "Claude" }
        guard showsFolder else { return email }
        return "\(email) (\(folderName ?? "~/.claude"))"
    }

    private var folderName: String? {
        guard let configDir else { return nil }
        return kind == .managed ? "added in app" : "~/" + configDir.lastPathComponent
    }

    /// The variable that points the CLI at this account. Removed for the
    /// standard folder, so a value inherited from a shell can't leak in.
    var cliEnvironment: [String: String?] {
        ["CLAUDE_CONFIG_DIR": configDir?.path]
    }
}

enum AccountDiscovery {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where Add Account keeps the folders it creates.
    static var managedRoot: URL {
        home.appendingPathComponent("Library/Application Support/ClaudeUsage/accounts", isDirectory: true)
    }

    /// Every account on this Mac: the standard one first (always — the
    /// claude.ai fallback hangs off it), then folders found in the home
    /// directory, then the ones added in the app. A folder that isn't signed
    /// in is skipped.
    ///
    /// Folders are never merged by address: `.claude.json` holds a cached
    /// profile that Claude Code may rewrite from another login, while the
    /// token each folder uses is its own. Two folders showing one address
    /// are both listed, labelled with their folder.
    static func discover() -> [ClaudeAccount] {
        var accounts = [ClaudeAccount(kind: .standard,
                                      configDir: nil,
                                      email: signedInEmail(home.appendingPathComponent(".claude.json")))]

        for dir in candidates(in: home, matching: { $0.hasPrefix(".claude") && $0 != ".claude" }) {
            if let email = signedInEmail(dir.appendingPathComponent(".claude.json")) {
                accounts.append(ClaudeAccount(kind: .found, configDir: dir, email: email))
            }
        }
        for dir in candidates(in: managedRoot, matching: { !$0.hasPrefix(".") }) {
            if let email = signedInEmail(dir.appendingPathComponent(".claude.json")) {
                accounts.append(ClaudeAccount(kind: .managed, configDir: dir, email: email))
            }
        }

        let counts = Dictionary(accounts.compactMap { $0.email?.lowercased() }.map { ($0, 1) }, uniquingKeysWith: +)
        for index in accounts.indices {
            if let email = accounts[index].email?.lowercased(), counts[email, default: 0] > 1 {
                accounts[index].showsFolder = true
            }
        }
        return accounts
    }

    private static func candidates(in parent: URL, matching: (String) -> Bool) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter(matching).sorted().compactMap { name in
            let url = parent.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return url
        }
    }

    /// The address a Claude Code config file is signed in with, if any.
    /// `.claude.json` carries the account under `oauthAccount`; the token
    /// itself lives in the keychain and is never touched here.
    static func signedInEmail(_ configFile: URL) -> String? {
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              !email.isEmpty else { return nil }
        return email
    }
}
