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

extension String {
    /// Full match plus capture groups, or nil when the pattern doesn't match.
    /// Optional groups that didn't participate come back as empty strings.
    func captures(_ pattern: String, caseInsensitive: Bool = false) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: self) else { return "" }
            return String(self[range])
        }
    }
}

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

    static func usageText(timeout: TimeInterval = 60) async throws -> String {
        guard let binary = locate() else { throw Subprocess.Failure.notFound("claude CLI") }
        return try await Subprocess.run(binary, ["-p", "/usage"],
                                       workingDirectory: Subprocess.scratchDirectory("cli"),
                                       timeout: timeout)
    }
}

@MainActor
class UsageManager: NSObject, ObservableObject {
    @Published var isLoggedIn = false
    @Published var usageData: UsageData?
    /// Weekly usage. Neutral until it passes 80 % of the weekly limit.
    @Published var displayPrimary = "..."
    @Published var displayPrimaryStatus: PaceStatus = .unknown
    /// Pace against today's budget — the only part that gets tinted.
    @Published var displayPace: String?
    @Published var lastUpdate: Date?
    @Published var errorMessage: String?
    @Published var autoRefresh = true
    /// Pace bucket the menu bar title is tinted with.
    @Published var displayStatus: PaceStatus = .unknown
    /// True while a read is in flight. The figures stay up throughout.
    @Published private(set) var isFetching = false
    /// Whether `displayPrimary` holds real figures, however old.
    @Published private(set) var hasFigures = false

    /// Past this, the figures on screen are shown dimmed: still the best we
    /// have, but no longer current. Three missed refreshes.
    private let staleAfterSeconds: TimeInterval = 15 * 60

    var isStale: Bool {
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) > staleAfterSeconds
    }

    private var refreshTimer: Timer?
    private let usageURL = URL(string: "https://claude.ai/settings/usage")!
    private let loginURL = URL(string: "https://claude.ai/login")!
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

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

    override init() {
        super.init()
        try? FileManager.default.removeItem(atPath: DebugLog.path)
        DebugLog.log("=== ClaudeUsage launched ===")
        restoreLastDisplay()
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

    /// The last figures we managed to read. A refresh takes seconds and the
    /// menu bar used to go blank for the whole of it — and blank again after
    /// every restart. Old numbers beat no numbers, so they are kept on screen
    /// and written to disk, dimmed once they go stale.
    private struct Snapshot: Codable {
        let primary: String
        let primaryStatus: PaceStatus
        let pace: String?
        let status: PaceStatus
        let updatedAt: Date
    }

    private static let snapshotKey = "lastDisplay"

    private func saveLastDisplay() {
        guard hasFigures, let lastUpdate else { return }
        let snapshot = Snapshot(primary: displayPrimary,
                                primaryStatus: displayPrimaryStatus,
                                pace: displayPace,
                                status: displayStatus,
                                updatedAt: lastUpdate)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    private func restoreLastDisplay() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        setStatus(snapshot.primary,
                  primaryStatus: snapshot.primaryStatus,
                  pace: snapshot.pace,
                  status: snapshot.status)
        lastUpdate = snapshot.updatedAt
        hasFigures = true
        DebugLog.log("restored last display: \(snapshot.primary) (read \(snapshot.updatedAt))")
    }

    private func forgetLastDisplay() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        hasFigures = false
        lastUpdate = nil
    }

    /// A failed read doesn't make the figures we already have wrong, so leave
    /// them up — the menu carries the error. Only say "!" when we have nothing.
    private func markFailed() {
        guard !hasFigures else { return }
        setStatus("!")
    }

    private func setStatus(_ text: String,
                           primaryStatus: PaceStatus = .unknown,
                           pace: String? = nil,
                           status: PaceStatus = .unknown) {
        displayPrimary = text
        displayPrimaryStatus = primaryStatus
        displayPace = pace
        displayStatus = status
    }

    // MARK: - Public actions

    /// Prefers the Claude Code CLI: `claude -p /usage` reports the plan limits
    /// straight from the server, costs nothing (no model call — measured at zero
    /// tokens and zero turns), needs no cookies, and gives the reset moment as a
    /// real date with a timezone instead of a bare weekday. Falls back to
    /// scraping the settings page if the CLI isn't usable.
    func fetchUsage() {
        guard !isFetching else {
            DebugLog.log("fetchUsage skipped, already fetching")
            return
        }
        isFetching = true
        errorMessage = nil
        lastFetchAt = Date()

        Task { @MainActor in
            do {
                let text = try await ClaudeCLI.usageText()
                isFetching = false
                if parseCLIOutput(text) { return }
                DebugLog.log("CLI output had no usage figures, falling back to web")
            } catch {
                DebugLog.log("CLI unavailable (\(error.localizedDescription)), falling back to web")
            }
            fetchUsageViaWeb()
        }
    }

    private func fetchUsageViaWeb() {
        Task { @MainActor in
            // Deferred until the fallback is actually needed — reading Chrome's
            // cookie key prompts for keychain access, which the CLI path avoids.
            if !didImportCookies {
                didImportCookies = true
                await importFromChromeIfNeeded(silentOnSuccess: true)
            }
            guard !isFetching else { return }
            DebugLog.log("fetchUsage via web -> \(usageURL.absoluteString)")
            isFetching = true
            pollAttempts = 0
            lastFetchAt = Date()
            fetchWebView.load(URLRequest(url: usageURL))
        }
    }

    func importFromChrome() {
        Task { @MainActor in
            errorMessage = nil
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
                self.errorMessage = err.localizedDescription
                self.markFailed()
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

    func logout() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)

        dataStore.removeData(ofTypes: dataTypes, modifiedSince: date) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoggedIn = false
                self.usageData = nil
                self.setStatus("...")
                self.forgetLastDisplay()
                self.stopRefreshTimer()
            }
        }
    }

    // MARK: - Auto-refresh

    func startRefreshTimer() {
        guard autoRefresh else { return }
        refreshTimer?.invalidate()
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
        guard isFetching else { return }

        fetchWebView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.isFetching else { return }

                let text = (result as? String) ?? ""
                let lower = text.lowercased()

                let looksLikeUsage = lower.contains("% used") || lower.contains("current session") || lower.contains("all models")
                let looksLikeLogin = lower.contains("continue with google") || lower.contains("continue with email") ||
                                     lower.contains("log in to claude") || lower.contains("sign in")

                if looksLikeUsage || looksLikeLogin {
                    DebugLog.log("pollForContent matched after \(self.pollAttempts) tries (usage=\(looksLikeUsage), login=\(looksLikeLogin)), text length=\(text.count), url=\(self.fetchWebView.url?.absoluteString ?? "nil")")
                    self.isFetching = false
                    self.parseUsageText(text)
                    return
                }

                self.pollAttempts += 1
                if self.pollAttempts >= self.maxPollAttempts {
                    DebugLog.log("pollForContent gave up after \(self.pollAttempts) tries; url=\(self.fetchWebView.url?.absoluteString ?? "nil"); text length=\(text.count); first 200: \(String(text.prefix(200)))")
                    self.isFetching = false
                    self.markFailed()
                    self.errorMessage = "Page didn't load — check /tmp/claude-usage-debug.log"
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
            isLoggedIn = false
            markFailed()
            errorMessage = "Not logged in"
            return
        }

        isLoggedIn = true
        startRefreshTimer()

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
        publish(data, source: "web")
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

    private func publish(_ data: UsageData, source: String) {
        DebugLog.log("Parsed[\(source)] - Current: \(data.currentSessionPercent ?? -1)% (reset: \(data.currentSessionReset ?? "?")), All: \(data.allModelsPercent ?? -1)% (reset: \(data.allModelsReset ?? "?")), \(data.sonnetLabel ?? "other"): \(data.sonnetPercent ?? -1)%, day \(data.weekDayIndex ?? -1)/7 (\(data.dayProgressPercent ?? -1)% in), expected \(data.expectedPercent ?? -1)%, ahead \(data.dayDeviationPercent ?? 0)%, status \(data.paceStatus)")

        if let all = data.allModelsPercent {
            setStatus(String(format: "%.0f%%", all),
                      // Neutral until the weekly figure is itself close to
                      // running out: orange from 90 %, red from 95 %.
                      primaryStatus: PaceStatus(percentOfLimit: all,
                                                warn: 90, danger: 95, green: false),
                      pace: data.expectedPercent.map { String(format: "%.0f%%", $0) },
                      status: data.paceStatus)
        } else {
            setStatus("?")
        }

        usageData = data
        lastUpdate = Date()
        errorMessage = nil
        hasFigures = data.allModelsPercent != nil
        saveLastDisplay()
    }

    // MARK: - CLI parsing

    /// Reads the three figures out of `claude -p /usage`:
    ///
    ///     Current session: 12% used · resets Aug 6 at 11am (Europe/Prague)
    ///     Current week (all models): 9% used · resets Aug 12 at 2pm (Europe/Prague)
    ///     Current week (Fable): 0% used
    ///
    /// Returns false if none of them were found, so the caller can fall back.
    private func parseCLIOutput(_ text: String) -> Bool {
        var data = UsageData()
        data.rawText = text

        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)

            if let m = line.captures(#"^Current session:\s*(\d+)%\s*used(?:\s*·\s*resets\s+(.+))?$"#) {
                data.currentSessionPercent = Double(m[1])
                data.currentSessionReset = m.count > 2 && !m[2].isEmpty ? m[2] : nil
            } else if let m = line.captures(#"^Current week \(([^)]+)\):\s*(\d+)%\s*used(?:\s*·\s*resets\s+(.+))?$"#) {
                let name = m[1]
                let percent = Double(m[2])
                let reset = m.count > 3 && !m[3].isEmpty ? m[3] : nil
                if name.lowercased() == "all models" {
                    data.allModelsPercent = percent
                    data.allModelsReset = reset
                } else if data.sonnetPercent == nil {
                    data.sonnetLabel = name
                    data.sonnetPercent = percent
                }
            }
        }

        guard data.allModelsPercent != nil || data.currentSessionPercent != nil else { return false }

        isLoggedIn = true
        startRefreshTimer()

        let now = Date()
        data.currentSessionResetDate = data.currentSessionReset.flatMap { Self.parseCLIReset($0, now: now) }
        data.allModelsResetDate = data.allModelsReset.flatMap { Self.parseCLIReset($0, now: now) }

        applyPacing(to: &data, now: now)
        publish(data, source: "cli")
        return true
    }

    /// "Aug 12 at 2pm (Europe/Prague)" — minutes are dropped on the hour, and the
    /// year is absent, so pick the nearest year that still lies ahead of now.
    static func parseCLIReset(_ text: String, now: Date) -> Date? {
        guard let m = text.captures(#"^(\w{3})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)\s*\(([^)]+)\)$"#,
                                    caseInsensitive: true),
              let day = Int(m[2]), let rawHour = Int(m[3]) else { return nil }

        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let month = months.firstIndex(of: m[1].lowercased())
                .map({ $0 + 1 }) else { return nil }

        let minute = Int(m[4]) ?? 0
        let hour = rawHour % 12 + (m[5].lowercased() == "pm" ? 12 : 0)

        var calendar = Calendar(identifier: .gregorian)
        guard let tz = TimeZone(identifier: m[6]) else { return nil }
        calendar.timeZone = tz

        let thisYear = calendar.component(.year, from: now)
        for year in [thisYear, thisYear + 1, thisYear - 1] {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            guard let date = calendar.date(from: components) else { continue }
            // Resets lie ahead; allow a day of slack for clock skew.
            if date > now.addingTimeInterval(-86_400) { return date }
        }
        return nil
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
            self.isFetching = false
            self.markFailed()
            self.errorMessage = error.localizedDescription
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard webView === self.fetchWebView else { return }
            self.isFetching = false
            self.markFailed()
            self.errorMessage = error.localizedDescription
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
