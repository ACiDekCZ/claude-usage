import Foundation
import WebKit
import AppKit
import Combine
import os

enum DebugLog {
    static let logger = Logger(subsystem: "cz.visek.milan.ClaudeUsage", category: "main")
    static let path = "/tmp/claude-usage-debug.log"

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(Date()): \(message)\n"
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
}

/// How the current weekly usage compares to the budget for the day we're in.
enum PaceStatus: String, Codable {
    case ok        // comfortably inside today's allowance
    case warning   // 80–100 % of today's allowance
    case over      // past today's allowance
    case unknown

    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .over: return .systemRed
        case .unknown: return .labelColor
        }
    }

    var label: String {
        switch self {
        case .ok: return "a full day's ration in hand"
        case .warning: return "just ahead of the line"
        case .over: return "well ahead of the line"
        case .unknown: return "behind the line"
        }
    }

    /// For a usage figure measured against its own limit: orange from `warn`,
    /// red from `danger`, otherwise neutral (or green when `green` is asked for).
    init(percentOfLimit: Double, warn: Double, danger: Double, green: Bool = true) {
        if percentOfLimit >= danger { self = .over }
        else if percentOfLimit >= warn { self = .warning }
        else { self = green ? .ok : .unknown }
    }

    /// How far weekly usage sits from the share of the week already elapsed —
    /// the level an even spread would have you at right now.
    ///
    /// - more than `warnBand` ahead of the line → red
    /// - anywhere ahead of it → orange
    /// - a full day's ration or more behind → green, there is a day to burn
    /// - otherwise → neutral
    init(aheadOfLine ahead: Double, dailyRation: Double, warnBand: Double = 3) {
        if ahead > warnBand { self = .over }
        else if ahead > 0 { self = .warning }
        else if ahead < -dailyRation { self = .ok }
        else { self = .unknown }
    }

    /// Menu items can't be tinted, so status is carried by an emoji instead.
    var dot: String {
        switch self {
        case .ok: return "🟢"
        case .warning: return "🟠"
        case .over: return "🔴"
        case .unknown: return "⚪️"
        }
    }
}

struct UsageData {
    var currentSessionPercent: Double?
    var currentSessionReset: String?
    var currentSessionResetDate: Date?
    var allModelsPercent: Double?
    var allModelsReset: String?
    var allModelsResetDate: Date?
    var allModelsTimeLeft: String?      // e.g. "3d 5h"
    var allModelsTimePercent: Double?   // % of week elapsed
    var sonnetPercent: Double?
    var sonnetLabel: String?            // page now names this row per model (e.g. "Fable")
    var rawText: String?

    // Daily pacing of the weekly limit
    var weekDayIndex: Int?              // 1...7 — which day of the weekly window we're in
    var dayProgressPercent: Double?     // how far into that day we are, 0...100
    /// The figure shown in the menu bar next to usage: the share of the week
    /// already elapsed, i.e. the level an even spread would have you at right
    /// now. Grows continuously, so it never jumps at a day boundary.
    var expectedPercent: Double?
    /// allModelsPercent − expectedPercent. Positive means ahead of the line.
    var dayDeviationPercent: Double?
    var paceStatus: PaceStatus = .unknown
}

/// One day's share of the weekly limit (100 % / 7 days ≈ 14.3 %).
let dailyAllowancePercent: Double = 100.0 / 7.0

/// Runs the Claude Code CLI to read the plan limits.
enum ClaudeCLI {
    /// A GUI app doesn't inherit the shell PATH, so look where it actually lands.
    static func locate() -> URL? {
        Subprocess.locate([
            "~/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ])
    }

    enum Problem: LocalizedError {
        /// A Claude Code too old to know the request.
        case unsupported(String)
        /// Signed out, or signed in with an API key: no plan limits to show.
        case noLimits
        case noAnswer

        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): return "Update Claude Code (\(reason.prefix(60)))"
            case .noLimits: return "Not signed in to a Claude plan"
            case .noAnswer: return "claude gave no usage figures"
            }
        }
    }

    /// The plan's limits, asked with the control request `get_usage` on
    /// stdin of `claude -p --input-format stream-json`. With `skip_behaviors`
    /// it reports the limits alone, straight from the server, in a second or
    /// two, without calling a model. `claude -p /usage` would also sum up
    /// every conversation kept on the Mac from the past week ("What's
    /// contributing to your usage?"), which takes a minute and more on a busy
    /// one — and nothing here shows that breakdown.
    static func limits(for account: ClaudeAccount, timeout: TimeInterval = 60) async throws -> PlanLimits {
        guard let binary = locate() else { throw Subprocess.Failure.notFound("claude CLI") }
        let id = "claude-usage-\(UUID().uuidString)"
        let request = #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        let output = try await Subprocess.run(binary,
                                              ["-p", "--input-format", "stream-json",
                                               "--output-format", "stream-json", "--verbose"],
                                              workingDirectory: Subprocess.scratchDirectory("cli"),
                                              environment: account.cliEnvironment,
                                              input: request + "\n",
                                              timeout: timeout)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for line in output.split(separator: "\n") where line.contains(id) {
            guard let reply = try? decoder.decode(ControlLine.self, from: Data(line.utf8)),
                  reply.type == "control_response",
                  let response = reply.response, response.requestId == id else { continue }
            guard response.subtype == "success" else {
                throw Problem.unsupported(response.error ?? "get_usage failed")
            }
            guard let limits = response.response,
                  limits.rateLimitsAvailable == true, limits.rateLimits != nil else {
                throw Problem.noLimits
            }
            return limits
        }
        throw Problem.noAnswer
    }

    /// One line of the stream-json output; only the answer to our request is read.
    private struct ControlLine: Decodable {
        struct Response: Decodable {
            let subtype: String?
            let requestId: String?
            let response: PlanLimits?
            let error: String?
        }
        let type: String?
        let response: Response?
    }
}

/// What `get_usage` reports: utilization 0–100 and the reset moment of each
/// window (none for a window not begun yet).
struct PlanLimits: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }
    struct ModelWindow: Decodable {
        let displayName: String?
        let utilization: Double?
        let resetsAt: String?
    }
    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        /// Weekly limits of a single model, e.g. "Fable".
        let modelScoped: [ModelWindow]?
    }

    let rateLimitsAvailable: Bool?
    let rateLimits: RateLimits?

    /// "2026-11-25T12:00:00.073795+00:00" — microseconds, which
    /// ISO8601DateFormatter won't take, so the fraction is dropped.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}

/// Everything shown for one account: its figures, how old they are, and
/// what went wrong reading them.
struct AccountUsage: Identifiable {
    var account: ClaudeAccount
    var id: String { account.id }

    var isLoggedIn = false
    var usageData: UsageData?
    /// Weekly usage. Neutral until it passes 90 % of the weekly limit.
    var displayPrimary = "..."
    var displayPrimaryStatus: PaceStatus = .unknown
    /// Share of the week elapsed — the only part tinted by pace.
    var displayPace: String?
    /// Pace bucket `displayPace` is tinted with.
    var displayStatus: PaceStatus = .unknown
    var lastUpdate: Date?
    var errorMessage: String?
    /// True while a read is in flight. The figures stay up throughout.
    var isFetching = false
    /// Whether `displayPrimary` holds real figures, however old.
    var hasFigures = false

    /// Past this, the figures on screen are shown dimmed: still the best we
    /// have, but no longer current. Three missed refreshes.
    static let staleAfterSeconds: TimeInterval = 15 * 60

    var isStale: Bool {
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) > Self.staleAfterSeconds
    }

    init(account: ClaudeAccount) {
        self.account = account
    }

    mutating func setStatus(_ text: String,
                            primaryStatus: PaceStatus = .unknown,
                            pace: String? = nil,
                            status: PaceStatus = .unknown) {
        displayPrimary = text
        displayPrimaryStatus = primaryStatus
        displayPace = pace
        displayStatus = status
    }

    /// A failed read doesn't make the figures we already have wrong, so leave
    /// them up — the menu carries the error. Only say "!" when we have nothing.
    mutating func markFailed(_ message: String? = nil) {
        if let message { errorMessage = message }
        guard !hasFigures else { return }
        setStatus("!")
    }
}

@MainActor
class UsageManager: NSObject, ObservableObject {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// The standard account always comes first, and the claude.ai fallback
    /// is tied to it.
    static let defaultID = "default"

    /// Every account found, in display order — the standard one first.
    @Published private(set) var accounts: [AccountUsage] = []
    @Published var autoRefresh = true
    /// Accounts left out of the menu bar title. They stay in the menu.
    @Published private(set) var hiddenInMenuBar: Set<String> = []
    @Published private(set) var isAddingAccount = false

    var isFetching: Bool { accounts.contains { $0.isFetching } }
    var isLoggedIn: Bool { accounts.contains { $0.isLoggedIn } }
    var hasMultipleAccounts: Bool { accounts.count > 1 }

    /// The accounts the menu bar title shows, in order.
    var menuBarAccounts: [AccountUsage] {
        accounts.filter { !hiddenInMenuBar.contains($0.id) }
    }

    /// When the oldest figures on screen were read.
    var lastUpdate: Date? {
        accounts.filter(\.hasFigures).compactMap(\.lastUpdate).min()
    }

    /// Whether any figure in the menu bar has gone stale.
    var isStale: Bool { menuBarAccounts.contains { $0.isStale } }

    private var refreshTimer: Timer?
    private let usageURL = URL(string: "https://claude.ai/settings/usage")!
    private let loginURL = URL(string: "https://claude.ai/login")!
    private let userAgent = UsageManager.userAgent

    // Skip refresh when user has been idle (no mouse/keyboard) for this long.
    private let idleThresholdSeconds: TimeInterval = 600
    private let refreshIntervalSeconds: TimeInterval = 300
    private let tickIntervalSeconds: TimeInterval = 60
    private var isSystemAsleep = false
    private var lastFetchAt: Date?

    private var fetchWebView: WKWebView!
    private var pollAttempts = 0
    private let maxPollAttempts = 30   // 30 * 500ms = 15s

    private var loginWindow: NSWindow?
    private var loginWebView: WKWebView?
    private var didImportCookies = false
    private let accountLogin = AccountLogin()

    override init() {
        super.init()
        try? FileManager.default.removeItem(atPath: DebugLog.path)
        DebugLog.log("=== ClaudeUsage launched ===")
        hiddenInMenuBar = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        refreshAccounts()
        setupFetchWebView()
        setupActivityObservers()
        DebugLog.log("claude CLI: \(ClaudeCLI.locate()?.path ?? "not found")")
        Task { @MainActor in
            fetchUsage()
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Accounts

    func state(_ id: String) -> AccountUsage? {
        accounts.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout AccountUsage) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
    }

    /// Looks for accounts again — a folder may have been signed in or out
    /// since — keeping the figures of the ones still there.
    private func refreshAccounts() {
        let found = AccountDiscovery.discover()
        let snapshots = loadSnapshots()
        let updated = found.map { account -> AccountUsage in
            if var existing = state(account.id) {
                existing.account = account
                return existing
            }
            var fresh = AccountUsage(account: account)
            if let snapshot = snapshots[account.id] {
                fresh.setStatus(snapshot.primary,
                                primaryStatus: snapshot.primaryStatus,
                                pace: snapshot.pace,
                                status: snapshot.status)
                fresh.lastUpdate = snapshot.updatedAt
                fresh.hasFigures = true
                DebugLog.log("restored last display for \(account.label): \(snapshot.primary) (read \(snapshot.updatedAt))")
            }
            return fresh
        }
        if updated.map(\.id) != accounts.map(\.id) {
            DebugLog.log("accounts: \(found.map { "\($0.label) [\($0.configDir?.path ?? "~/.claude")]" }.joined(separator: ", "))")
        }
        accounts = updated
    }

    func toggleMenuBar(_ id: String) {
        if hiddenInMenuBar.contains(id) { hiddenInMenuBar.remove(id) } else { hiddenInMenuBar.insert(id) }
        UserDefaults.standard.set(Array(hiddenInMenuBar), forKey: Self.hiddenKey)
    }

    private static let hiddenKey = "hiddenInMenuBar"

    /// Signs a further account in through `claude auth login`, into a config
    /// folder of the app's own — see `AccountLogin`.
    func addAccount() {
        let existing = Set(accounts.compactMap { $0.account.email?.lowercased() })
        isAddingAccount = true
        accountLogin.start(existingEmails: existing) { [weak self] outcome in
            guard let self else { return }
            self.isAddingAccount = false
            switch outcome {
            case .added(let email):
                DebugLog.log("add account: added \(email)")
                self.refreshAccounts()
                if let account = self.accounts.last(where: { $0.account.kind == .managed && $0.account.email == email })?.account {
                    self.lastFetchAt = Date()
                    Task { await self.fetch(account) }
                }
            case .duplicate(let email):
                Self.alert("\(email) is already listed",
                           "Each account is shown once; this sign-in was undone.")
            case .cancelled:
                break
            case .failed(let message):
                Self.alert("The account wasn't added", message)
            }
        }
    }

    /// Only an account the app added can be removed — the folders it found
    /// belong to the user, and the menu bar is the place to hide those.
    func removeAccount(_ id: String) {
        guard let account = state(id)?.account, account.kind == .managed,
              let dir = account.configDir else { return }

        let alert = NSAlert()
        alert.messageText = "Remove \(account.label)?"
        alert.informativeText = "Claude Usage signs this account out and stops showing it. Other Claude Code logins are not affected."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            await AccountLogin.discard(dir)
            var snapshots = loadSnapshots()
            snapshots[id] = nil
            saveSnapshots(snapshots)
            hiddenInMenuBar.remove(id)
            UserDefaults.standard.set(Array(hiddenInMenuBar), forKey: Self.hiddenKey)
            refreshAccounts()
            DebugLog.log("removed account \(account.label)")
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Activity

    private func setupActivityObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let pause: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        let resume: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in pause {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleSystemInactive(name.rawValue) }
            }
        }
        for name in resume {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleSystemActive(name.rawValue) }
            }
        }
    }

    private func handleSystemInactive(_ reason: String) {
        DebugLog.log("system inactive (\(reason)) — pausing refresh")
        isSystemAsleep = true
        stopRefreshTimer()
    }

    private func handleSystemActive(_ reason: String) {
        DebugLog.log("system active (\(reason)) — resuming refresh")
        isSystemAsleep = false
        guard isLoggedIn, autoRefresh else { return }
        startRefreshTimer()
        fetchUsage()
    }

    /// Seconds since the user's last keyboard or mouse event (across login sessions).
    private func userIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    private func setupFetchWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        fetchWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        fetchWebView.customUserAgent = userAgent
        fetchWebView.navigationDelegate = self
    }

    // MARK: - Last figures

    /// The last figures we managed to read, per account. A refresh takes
    /// seconds and the menu bar used to go blank for the whole of it — and
    /// blank again after every restart. Old numbers beat no numbers, so they
    /// are kept on screen and written to disk, dimmed once they go stale.
    private struct Snapshot: Codable {
        let primary: String
        let primaryStatus: PaceStatus
        let pace: String?
        let status: PaceStatus
        let updatedAt: Date
    }

    private static let snapshotsKey = "lastDisplays"
    /// Where a single account's figures were kept before there could be more.
    private static let legacySnapshotKey = "lastDisplay"

    private func loadSnapshots() -> [String: Snapshot] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.snapshotsKey),
           let snapshots = try? JSONDecoder().decode([String: Snapshot].self, from: data) {
            return snapshots
        }
        if let data = defaults.data(forKey: Self.legacySnapshotKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return [Self.defaultID: snapshot]
        }
        return [:]
    }

    private func saveSnapshots(_ snapshots: [String: Snapshot]) {
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.snapshotsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacySnapshotKey)
        }
    }

    private func saveLastDisplay(_ id: String) {
        guard let state = state(id), state.hasFigures, let lastUpdate = state.lastUpdate else { return }
        var snapshots = loadSnapshots()
        snapshots[id] = Snapshot(primary: state.displayPrimary,
                                 primaryStatus: state.displayPrimaryStatus,
                                 pace: state.displayPace,
                                 status: state.displayStatus,
                                 updatedAt: lastUpdate)
        saveSnapshots(snapshots)
    }

    private func forgetLastDisplay(_ id: String) {
        var snapshots = loadSnapshots()
        snapshots[id] = nil
        saveSnapshots(snapshots)
        update(id) {
            $0.hasFigures = false
            $0.lastUpdate = nil
        }
    }

    // MARK: - Public actions

    /// Prefers the Claude Code CLI: its `get_usage` request reports the plan
    /// limits straight from the server in a second or two, costs nothing (no
    /// model call), needs no cookies, and gives each reset as an exact moment.
    /// Every account is read this way, one after another. Only the standard
    /// one falls back to scraping the settings page if the CLI isn't usable.
    func fetchUsage() {
        guard !isFetching else {
            DebugLog.log("fetchUsage skipped, already fetching")
            return
        }
        refreshAccounts()
        lastFetchAt = Date()
        let queue = accounts.map(\.account)
        for account in queue {
            update(account.id) { $0.isFetching = true }
        }
        Task { @MainActor in
            for account in queue {
                await fetch(account)
            }
        }
    }

    private func fetch(_ account: ClaudeAccount) async {
        let id = account.id
        update(id) {
            $0.isFetching = true
            $0.errorMessage = nil
        }

        var failure: String
        do {
            let limits = try await ClaudeCLI.limits(for: account)
            update(id) { $0.isFetching = false }
            if let data = usageData(from: limits) {
                publish(data, for: id, source: "cli")
                return
            }
            DebugLog.log("get_usage for \(account.label) had no usage figures")
            failure = ClaudeCLI.Problem.noAnswer.localizedDescription
        } catch Subprocess.Failure.timedOut(let tool, let after) {
            // Slow, not broken: claude.ai wouldn't do better, so keep what we
            // have and try again next round.
            update(id) {
                $0.isFetching = false
                $0.markFailed("\(tool) took longer than \(Int(after)) s")
            }
            DebugLog.log("CLI timed out for \(account.label) after \(Int(after)) s")
            return
        } catch {
            update(id) { $0.isFetching = false }
            DebugLog.log("CLI unavailable for \(account.label) (\(error.localizedDescription))")
            failure = error.localizedDescription
        }

        if account.kind == .standard {
            DebugLog.log("falling back to web")
            fetchUsageViaWeb()
        } else {
            update(id) { $0.markFailed(failure) }
        }
    }

    /// Whether the standard account's claude.ai read is in flight.
    private var webFetching: Bool {
        get { state(Self.defaultID)?.isFetching ?? false }
        set { update(Self.defaultID) { $0.isFetching = newValue } }
    }

    private func fetchUsageViaWeb() {
        Task { @MainActor in
            // Deferred until the fallback is actually needed — reading Chrome's
            // cookie key prompts for keychain access, which the CLI path avoids.
            if !didImportCookies {
                didImportCookies = true
                await importFromChromeIfNeeded(silentOnSuccess: true)
            }
            guard !webFetching else { return }
            DebugLog.log("fetchUsage via web -> \(usageURL.absoluteString)")
            webFetching = true
            pollAttempts = 0
            fetchWebView.load(URLRequest(url: usageURL))
        }
    }

    func importFromChrome() {
        Task { @MainActor in
            update(Self.defaultID) { $0.errorMessage = nil }
            let ok = await importFromChromeIfNeeded(silentOnSuccess: false)
            if ok {
                fetchUsage()
            }
        }
    }

    /// Reads sessionKey from Chrome and injects into our WKWebsiteDataStore.
    /// Returns true on success. Sets errorMessage on failure unless silentOnSuccess is true and there's already a logged-in state.
    @discardableResult
    private func importFromChromeIfNeeded(silentOnSuccess: Bool) async -> Bool {
        let result: Result<[ChromeCookie], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let cookies = try ChromeCookieImporter.importClaudeCookies()
                return .success(cookies)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let cookies):
            await injectCookies(cookies)
            let hasSession = cookies.contains { $0.name == "sessionKey" }
            DebugLog.log("imported \(cookies.count) cookies from Chrome (sessionKey: \(hasSession))")
            return true
        case .failure(let err):
            DebugLog.log("Chrome import failed: \(err.localizedDescription)")
            if !silentOnSuccess {
                update(Self.defaultID) { $0.markFailed(err.localizedDescription) }
            }
            return false
        }
    }

    private func injectCookies(_ cookies: [ChromeCookie]) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: cookie.hostKey,
                .path: cookie.path.isEmpty ? "/" : cookie.path,
                .secure: cookie.isSecure
            ]
            // Chrome stores expires_utc as microseconds since 1601-01-01.
            // Convert to seconds since 1970-01-01: subtract 11644473600 seconds.
            if cookie.expiresUtc > 0 {
                let unixSeconds = Double(cookie.expiresUtc) / 1_000_000.0 - 11_644_473_600
                if unixSeconds > Date().timeIntervalSince1970 {
                    props[.expires] = Date(timeIntervalSince1970: unixSeconds)
                }
            }
            if let httpCookie = HTTPCookie(properties: props) {
                await store.setCookie(httpCookie)
            } else {
                DebugLog.log("HTTPCookie(properties:) returned nil for \(cookie.name)@\(cookie.hostKey)")
            }
        }
    }

    func showLogin() {
        if let window = loginWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let lwv = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 760), configuration: config)
        lwv.customUserAgent = userAgent
        loginWebView = lwv

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude.ai Login"
        window.contentView = lwv
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        loginWindow = window

        lwv.load(URLRequest(url: loginURL))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Clears the claude.ai session the fallback reads with, and the standard
    /// account's figures along with it.
    func logout() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)

        dataStore.removeData(ofTypes: dataTypes, modifiedSince: date) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.update(Self.defaultID) {
                    $0.isLoggedIn = false
                    $0.usageData = nil
                    $0.setStatus("...")
                }
                self.forgetLastDisplay(Self.defaultID)
                if !self.isLoggedIn { self.stopRefreshTimer() }
            }
        }
    }

    // MARK: - Auto-refresh

    func startRefreshTimer() {
        guard autoRefresh, refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: tickIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerTick()
            }
        }
    }

    private func timerTick() {
        // Even when nothing is fetched, the title is redrawn: the figures dim
        // as they go stale, and the menu's "updated N ago" has to move.
        objectWillChange.send()
        if isSystemAsleep { return }
        let idle = userIdleSeconds()
        if idle > idleThresholdSeconds { return }
        if let last = lastFetchAt, Date().timeIntervalSince(last) < refreshIntervalSeconds { return }
        fetchUsage()
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func toggleAutoRefresh() {
        autoRefresh.toggle()
        if autoRefresh {
            startRefreshTimer()
            fetchUsage()
        } else {
            stopRefreshTimer()
        }
    }

    // MARK: - Page text extraction

    private func pollForContent() {
        guard webFetching else { return }

        fetchWebView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.webFetching else { return }

                let text = (result as? String) ?? ""
                let lower = text.lowercased()

                let looksLikeUsage = lower.contains("% used") || lower.contains("current session") || lower.contains("all models")
                let looksLikeLogin = lower.contains("continue with google") || lower.contains("continue with email") ||
                                     lower.contains("log in to claude") || lower.contains("sign in")

                if looksLikeUsage || looksLikeLogin {
                    DebugLog.log("pollForContent matched after \(self.pollAttempts) tries (usage=\(looksLikeUsage), login=\(looksLikeLogin)), text length=\(text.count), url=\(self.fetchWebView.url?.absoluteString ?? "nil")")
                    self.webFetching = false
                    self.parseUsageText(text)
                    return
                }

                self.pollAttempts += 1
                if self.pollAttempts >= self.maxPollAttempts {
                    DebugLog.log("pollForContent gave up after \(self.pollAttempts) tries; url=\(self.fetchWebView.url?.absoluteString ?? "nil"); text length=\(text.count); first 200: \(String(text.prefix(200)))")
                    self.webFetching = false
                    self.update(Self.defaultID) {
                        $0.markFailed("Page didn't load — check /tmp/claude-usage-debug.log")
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
                self.pollForContent()
            }
        }
    }

    // MARK: - Parsing

    private func parseUsageText(_ text: String) {
        var data = UsageData()
        data.rawText = text

        let lowerText = text.lowercased()
        if lowerText.contains("continue with google") || lowerText.contains("continue with email") ||
           lowerText.contains("log in to claude") {
            update(Self.defaultID) {
                $0.isLoggedIn = false
                $0.markFailed("Not logged in")
            }
            return
        }

        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        enum Section { case none, session, allModels, otherModel }
        var section: Section = .none

        for line in lines {
            let lower = line.lowercased()

            // "Usage credits" further down the page has its own "Resets …"/"0% used"
            // rows that would otherwise overwrite the plan limits.
            if lower.hasPrefix("usage credits") { break }

            if lower.contains("current session") {
                section = .session
            } else if lower.contains("all models") {
                section = .allModels
            } else if lower.contains("sonnet only") {
                section = .otherModel
            } else if section == .allModels,
                      data.allModelsPercent != nil,
                      !line.isEmpty,
                      !lower.hasPrefix("resets"),
                      !lower.hasSuffix("used"),
                      !lower.contains("%") {
                // A bare model name ("Fable", "Sonnet") after the All models block
                // starts a per-model section.
                section = .otherModel
                if data.sonnetLabel == nil { data.sonnetLabel = line }
            }

            if lower.hasPrefix("resets") {
                var resetValue = line
                for prefix in ["Resets in ", "Resets "] {
                    if resetValue.hasPrefix(prefix) {
                        resetValue = String(resetValue.dropFirst(prefix.count))
                        break
                    }
                }
                // First value wins — later sections must not overwrite the plan limits.
                switch section {
                case .session where data.currentSessionReset == nil:
                    data.currentSessionReset = resetValue
                case .allModels where data.allModelsReset == nil:
                    data.allModelsReset = resetValue
                default:
                    break
                }
            }

            if line.hasSuffix("% used") || line.hasSuffix("used") {
                if let match = line.range(of: #"(\d+)%"#, options: .regularExpression),
                   let pct = Double(line[match].dropLast()) {
                    switch section {
                    case .session where data.currentSessionPercent == nil:
                        data.currentSessionPercent = pct
                    case .allModels where data.allModelsPercent == nil:
                        data.allModelsPercent = pct
                    case .otherModel where data.sonnetPercent == nil:
                        data.sonnetPercent = pct
                    default:
                        break
                    }
                }
            }
        }

        let now = Date()
        if let resetStr = data.currentSessionReset {
            data.currentSessionResetDate = resolveResetDate(from: resetStr, now: now)
        }
        if let resetStr = data.allModelsReset {
            data.allModelsResetDate = resolveResetDate(from: resetStr, now: now)
        }

        applyPacing(to: &data, now: now)
        publish(data, for: Self.defaultID, source: "web")
    }

    /// Derives everything the display needs from the weekly reset moment.
    /// Shared by both the CLI and the web path.
    private func applyPacing(to data: inout UsageData, now: Date) {
        guard let resetDate = data.allModelsResetDate else { return }

        data.allModelsTimeLeft = Self.compactDuration(resetDate.timeIntervalSince(now))

        // Day 1 starts when the weekly window opened (one week before the reset).
        let weekSeconds: Double = 7 * 24 * 3600
        let weekStart = resetDate.addingTimeInterval(-weekSeconds)
        let elapsedFraction = min(1, max(0, now.timeIntervalSince(weekStart) / weekSeconds))
        data.allModelsTimePercent = elapsedFraction * 100

        let elapsedDays = elapsedFraction * 7
        let dayIndex = min(7, max(1, Int(floor(elapsedDays)) + 1))
        data.weekDayIndex = dayIndex
        data.dayProgressPercent = (elapsedDays - floor(elapsedDays)) * 100

        // Where an even spread would have you *right now*. Using elapsed time
        // rather than a per-day step means the target grows smoothly, so the
        // reading doesn't jump at a day boundary.
        let expected = elapsedFraction * 100
        data.expectedPercent = expected

        if let used = data.allModelsPercent {
            let ahead = used - expected
            data.dayDeviationPercent = ahead
            data.paceStatus = PaceStatus(aheadOfLine: ahead,
                                         dailyRation: dailyAllowancePercent)
        }
    }

    private func publish(_ data: UsageData, for id: String, source: String) {
        DebugLog.log("Parsed[\(source), \(state(id)?.account.label ?? id)] - Current: \(data.currentSessionPercent ?? -1)% (reset: \(data.currentSessionReset ?? "?")), All: \(data.allModelsPercent ?? -1)% (reset: \(data.allModelsReset ?? "?")), \(data.sonnetLabel ?? "other"): \(data.sonnetPercent ?? -1)%, day \(data.weekDayIndex ?? -1)/7 (\(data.dayProgressPercent ?? -1)% in), expected \(data.expectedPercent ?? -1)%, ahead \(data.dayDeviationPercent ?? 0)%, status \(data.paceStatus)")

        // A read that found no weekly figure says nothing new; it mustn't
        // wipe the figures already on screen.
        if data.allModelsPercent == nil, state(id)?.hasFigures == true {
            update(id) { $0.markFailed("No usage figures in the \(source) read") }
            return
        }

        update(id) { state in
            if let all = data.allModelsPercent {
                state.setStatus(String(format: "%.0f%%", all),
                                // Neutral until the weekly figure is itself close to
                                // running out: orange from 90 %, red from 95 %.
                                primaryStatus: PaceStatus(percentOfLimit: all,
                                                          warn: 90, danger: 95, green: false),
                                pace: data.expectedPercent.map { String(format: "%.0f%%", $0) },
                                status: data.paceStatus)
            } else {
                state.setStatus("?")
            }
            state.isLoggedIn = true
            state.usageData = data
            state.lastUpdate = Date()
            state.errorMessage = nil
            state.hasFigures = data.allModelsPercent != nil
        }
        saveLastDisplay(id)
        startRefreshTimer()
    }

    // MARK: - CLI figures

    /// The figures shown, from what `get_usage` reported. Nil when it gave
    /// neither the session nor the week.
    private func usageData(from limits: PlanLimits) -> UsageData? {
        guard let rates = limits.rateLimits else { return nil }
        var data = UsageData()
        if let session = rates.fiveHour, let used = session.utilization {
            data.currentSessionPercent = used
            data.currentSessionResetDate = PlanLimits.date(session.resetsAt)
        }
        if let week = rates.sevenDay, let used = week.utilization {
            data.allModelsPercent = used
            data.allModelsResetDate = PlanLimits.date(week.resetsAt)
        }
        if let model = rates.modelScoped?.first, let used = model.utilization {
            data.sonnetLabel = model.displayName
            data.sonnetPercent = used
        }
        guard data.allModelsPercent != nil || data.currentSessionPercent != nil else { return nil }

        applyPacing(to: &data, now: Date())
        return data
    }

    /// Turns a reset string from the usage page into an absolute date.
    /// Handles both formats:
    /// - "Sat 9:00 AM" (absolute day/time)
    /// - "16 hr 37 min" / "5 days 3 hr" (relative time)
    private func resolveResetDate(from resetString: String, now: Date) -> Date? {
        let lower = resetString.lowercased()

        if lower.contains("hr") || lower.contains("min") || lower.contains("day") {
            var totalMinutes = 0
            let parts = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            for i in 1..<max(1, parts.count) {
                guard let value = Int(parts[i - 1]) else { continue }
                let unit = parts[i]
                if unit.hasPrefix("day") { totalMinutes += value * 24 * 60 }
                else if unit.hasPrefix("hr") || unit.hasPrefix("hour") { totalMinutes += value * 60 }
                else if unit.hasPrefix("min") { totalMinutes += value }
            }

            if totalMinutes > 0 {
                return now.addingTimeInterval(Double(totalMinutes) * 60)
            }
        }

        let parts = resetString.components(separatedBy: " ")
        let dayMap = ["Sun": 1, "Mon": 2, "Tue": 3, "Wed": 4, "Thu": 5, "Fri": 6, "Sat": 7]

        guard parts.count >= 3, let targetWeekday = dayMap[parts[0]] else { return nil }

        let timeParts = parts[1].components(separatedBy: ":")
        let ampm = parts[2].uppercased()
        guard timeParts.count == 2,
              var hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]) else { return nil }

        if ampm == "PM" && hour != 12 { hour += 12 }
        if ampm == "AM" && hour == 12 { hour = 0 }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = targetWeekday
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var resetDate = calendar.date(from: components) else { return nil }
        if resetDate <= now {
            resetDate = calendar.date(byAdding: .weekOfYear, value: 1, to: resetDate) ?? resetDate
        }
        return resetDate
    }

    /// "−9%" / "+5%" / "±0%". Sign is taken from the rounded value so a
    /// deviation of -0.4 doesn't render as "−0%".
    static func signedPercent(_ value: Double) -> String {
        let rounded = value.rounded()
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "±")
        return String(format: "%@%.0f%%", sign, abs(rounded))
    }

    /// "3d 5h" / "5h 12m" / "12m"
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Absolute wall-clock rendering of a reset moment, e.g. "Sat 9:00".
    static func absoluteReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return formatter.string(from: date)
    }
}

// MARK: - WKNavigationDelegate

extension UsageManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard webView === self.fetchWebView else { return }
            DebugLog.log("didFinish navigation, url=\(webView.url?.absoluteString ?? "nil")")
            self.pollAttempts = 0
            self.pollForContent()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard webView === self.fetchWebView else { return }
            self.webFetching = false
            self.update(Self.defaultID) { $0.markFailed(error.localizedDescription) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard webView === self.fetchWebView else { return }
            self.webFetching = false
            self.update(Self.defaultID) { $0.markFailed(error.localizedDescription) }
        }
    }
}

// MARK: - NSWindowDelegate (login window)

extension UsageManager: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.loginWindow = nil
            self.loginWebView = nil
            self.fetchUsage()
        }
    }
}
