import AppKit
import WebKit

/// Adds a Claude account without leaving the app.
///
/// Runs `claude auth login` against a fresh config folder of the app's own.
/// The CLI hands its sign-in page to whatever `BROWSER` names, so it gets a
/// small script that passes the address back here instead of opening Chrome —
/// where the account already in use is signed in. The page opens in a window
/// with a private, throwaway session; once signed in it redirects to the
/// CLI's localhost callback, the CLI stores the token and exits.
@MainActor
final class AccountLogin: NSObject {
    enum Outcome {
        case added(String)
        case duplicate(String)
        case cancelled
        case failed(String)
    }

    private var process: Process?
    private var window: NSWindow?
    private var configDir: URL?
    private var urlFile: URL?
    private var existingEmails: Set<String> = []
    private var completion: ((Outcome) -> Void)?
    private var cancelled = false

    var isRunning: Bool { process != nil }

    /// - Parameter existingEmails: accounts already listed, lower-cased; a
    ///   sign-in to one of them is undone rather than listed twice.
    func start(existingEmails: Set<String>, completion: @escaping (Outcome) -> Void) {
        if isRunning {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let binary = ClaudeCLI.locate() else {
            completion(.failed("Adding an account needs Claude Code installed"))
            return
        }

        let dir = AccountDiscovery.managedRoot
            .appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased(), isDirectory: true)
        let loginDir = Subprocess.scratchDirectory("login")
        let urlFile = loginDir.appendingPathComponent("sign-in-url.txt")
        let script = loginDir.appendingPathComponent("open-url.sh")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: urlFile)
            try "#!/bin/sh\nprintf '%s' \"$1\" > \"$CLAUDE_USAGE_SIGN_IN_URL\"\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            completion(.failed("Couldn't prepare the sign-in: \(error.localizedDescription)"))
            return
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = Subprocess.environment(for: binary, overrides: [
            "CLAUDE_CONFIG_DIR": dir.path,
            "BROWSER": script.path,
            "CLAUDE_USAGE_SIGN_IN_URL": urlFile.path
        ])
        process.currentDirectoryURL = Subprocess.scratchDirectory("cli")
        // Held open: the CLI also offers to take a pasted code, and an
        // empty stdin would read as the user giving up.
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in self?.processEnded(status: status, stderr: stderr) }
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            completion(.failed("Couldn't start claude: \(error.localizedDescription)"))
            return
        }

        DebugLog.log("add account: claude auth login -> \(dir.path)")
        self.process = process
        self.configDir = dir
        self.urlFile = urlFile
        self.existingEmails = existingEmails
        self.completion = completion
        self.cancelled = false
        waitForSignInURL(attempt: 0)
    }

    func cancel() {
        guard let process else { return }
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    // MARK: - Sign-in window

    private func waitForSignInURL(attempt: Int) {
        guard process != nil, let urlFile else { return }
        if let text = try? String(contentsOf: urlFile, encoding: .utf8),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme == "https" {
            showWindow(url)
            return
        }
        // Should the CLI ever stop honouring BROWSER it opens the default
        // browser itself, and signing in there finishes the job just the same.
        guard attempt < 60 else {
            DebugLog.log("add account: no sign-in URL from the CLI, left to the default browser")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.waitForSignInURL(attempt: attempt + 1)
        }
    }

    private func showWindow(_ url: URL) {
        let config = WKWebViewConfiguration()
        // A session of its own: the account to add, not whichever one is
        // signed in already.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 760), configuration: config)
        webView.customUserAgent = UsageManager.userAgent

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Claude Account — sign in with the account to add"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        webView.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    // MARK: - Outcome

    private func processEnded(status: Int32, stderr: String) {
        let dir = configDir
        let finish = completion
        let wasCancelled = cancelled
        process = nil
        configDir = nil
        completion = nil
        closeWindow()
        if let urlFile { try? FileManager.default.removeItem(at: urlFile) }
        guard let dir, let finish else { return }

        DebugLog.log("add account: claude auth login exited \(status)\(stderr.isEmpty ? "" : ": \(stderr.prefix(200))")")

        Task { @MainActor in
            guard status == 0, !wasCancelled,
                  let email = AccountDiscovery.signedInEmail(dir.appendingPathComponent(".claude.json"))
            else {
                await Self.discard(dir)
                finish(wasCancelled ? .cancelled : .failed("Sign-in didn't finish"))
                return
            }
            if existingEmails.contains(email.lowercased()) {
                await Self.discard(dir)
                finish(.duplicate(email))
            } else {
                finish(.added(email))
            }
        }
    }

    /// Signs a folder out — which drops its token from the keychain — and
    /// deletes it.
    static func discard(_ dir: URL) async {
        if AccountDiscovery.signedInEmail(dir.appendingPathComponent(".claude.json")) != nil,
           let binary = ClaudeCLI.locate() {
            do {
                _ = try await Subprocess.run(binary, ["auth", "logout"],
                                             workingDirectory: Subprocess.scratchDirectory("cli"),
                                             environment: ["CLAUDE_CONFIG_DIR": dir.path],
                                             timeout: 30)
            } catch {
                DebugLog.log("claude auth logout for \(dir.path) failed: \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

extension AccountLogin: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.cancel()
        }
    }
}
