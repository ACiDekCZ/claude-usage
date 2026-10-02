import Combine
import Foundation

/// What `ccusage monthly --json` reports: token counts and dollar cost per
/// month, broken down by model. This is spending across every coding agent it
/// finds logs for (Claude Code, Codex, Gemini …), not the plan limits the menu
/// bar shows — those come from `claude -p /usage`.
struct CCUsageReport {
    struct Model: Identifiable, Codable {
        let modelName: String
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        /// ccusage knows the model but not its price, so `cost` is short.
        let missingPricing: Bool?

        var id: String { modelName }
        var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    }

    struct Month: Identifiable, Codable {
        struct Metadata: Codable {
            let agents: [String]?
        }

        /// `2026-09`.
        let period: String
        let totalCost: Double
        let totalTokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let modelBreakdowns: [Model]
        let metadata: Metadata?

        var id: String { period }
        var agents: [String] { metadata?.agents ?? [] }
    }

    struct Totals: Decodable {
        let totalCost: Double
        let totalTokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let unpricedModels: [String]?
    }

    private struct Payload: Decodable {
        let monthly: [Month]
        let totals: Totals
    }

    /// Oldest month first, the way ccusage prints it.
    let months: [Month]
    let totals: Totals
    let generatedAt: Date

    /// The month we're in, if it's in the report.
    var currentMonth: Month? {
        let key = Self.periodFormatter.string(from: Date())
        return months.first { $0.period == key }
    }

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    init(json: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: json)
        months = payload.monthly
        totals = payload.totals
        generatedAt = Date()
    }

    /// A report put together from months we already have — the archive, or
    /// the archive merged with a fresh run — with the totals summed over them.
    init(months: [Month], generatedAt: Date) {
        self.months = months
        self.generatedAt = generatedAt
        let unpriced = Set(months.flatMap { $0.modelBreakdowns }
                               .filter { $0.missingPricing == true }
                               .map(\.modelName))
        totals = Totals(totalCost: months.reduce(0) { $0 + $1.totalCost },
                        totalTokens: months.reduce(0) { $0 + $1.totalTokens },
                        inputTokens: months.reduce(0) { $0 + $1.inputTokens },
                        outputTokens: months.reduce(0) { $0 + $1.outputTokens },
                        cacheCreationTokens: months.reduce(0) { $0 + $1.cacheCreationTokens },
                        cacheReadTokens: months.reduce(0) { $0 + $1.cacheReadTokens },
                        unpricedModels: unpriced.isEmpty ? nil : unpriced.sorted())
    }
}

/// Every month ccusage has ever reported, kept in a JSON file of our own.
///
/// Claude Code deletes old session logs, and ccusage can only count what is
/// still on disk — so without this a month would shrink and then vanish from
/// the report. Each run is merged in month by month, and for each month the
/// figure with more tokens wins: logs only ever go away, so a bigger count is
/// the more complete one. A finished month therefore settles by itself, and a
/// run after its logs are gone can't make it smaller.
///
/// The file is plain pretty-printed JSON, safe to read or copy at any time.
/// It is replaced atomically, the previous version is kept next to it as
/// `.bak`, and a file we can't parse is never written over.
enum UsageHistory {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeUsage/usage-history.json")

    private static var backupURL: URL { url.appendingPathExtension("bak") }

    struct Archive: Codable {
        var updatedAt: Date
        var months: [CCUsageReport.Month]
    }

    /// - Returns: nil when there is no archive yet.
    /// - Throws: when there is one but it can't be read — the caller must not
    ///   write over it then.
    static func load() throws -> Archive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Archive.self, from: Data(contentsOf: url))
    }

    /// Merges `fresh` into the archive on disk and saves it.
    /// - Returns: the merged archive, oldest month first.
    static func merge(_ fresh: [CCUsageReport.Month]) throws -> Archive {
        var byPeriod: [String: CCUsageReport.Month] = [:]
        for month in try load()?.months ?? [] { byPeriod[month.period] = month }
        for month in fresh {
            if let kept = byPeriod[month.period], kept.totalTokens > month.totalTokens { continue }
            byPeriod[month.period] = month
        }
        let archive = Archive(updatedAt: Date(),
                              months: byPeriod.values.sorted { $0.period < $1.period })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }
        // Written to a temporary file and renamed into place, so a crash
        // halfway leaves the old archive, never half a new one.
        try data.write(to: url, options: .atomic)
        return archive
    }
}

/// Runs `bunx ccusage monthly --json`.
enum CCUsageCLI {
    /// `bunx` is bun under another name; either spelling gets us the same run.
    private static func command() -> (URL, [String])? {
        if let bunx = Subprocess.locate([
            "~/.bun/bin/bunx",
            "/opt/homebrew/bin/bunx",
            "~/.local/bin/bunx",
            "/usr/local/bin/bunx"
        ]) {
            return (bunx, ["ccusage", "monthly", "--json"])
        }
        if let bun = Subprocess.locate([
            "~/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun"
        ]) {
            return (bun, ["x", "ccusage", "monthly", "--json"])
        }
        return nil
    }

    static var isAvailable: Bool { command() != nil }

    /// Reads every agent's log, so it takes a good ten seconds even warm — and
    /// longer the first time, when bun still has to fetch ccusage from npm.
    static func monthly(timeout: TimeInterval = 180) async throws -> CCUsageReport {
        guard let (executable, arguments) = command() else {
            throw Subprocess.Failure.notFound("bunx (install bun)")
        }
        let output = try await Subprocess.run(executable, arguments,
                                              workingDirectory: Subprocess.scratchDirectory("ccusage"),
                                              timeout: timeout)
        // A warning on stdout before the JSON would be unusual, but cheap to survive.
        guard let start = output.firstIndex(of: "{") else {
            throw Subprocess.Failure.exited(tool: "ccusage", status: 0,
                                            stderr: "no JSON in output")
        }
        return try CCUsageReport(json: Data(output[start...].utf8))
    }
}

/// Holds the last report and decides when to run ccusage again.
///
/// Nothing runs at launch: the first run starts when the menu is opened, and
/// then only once the last attempt has gone stale. Each run costs a few
/// seconds of full-tilt CPU, so it isn't something to do on a timer.
@MainActor
final class CCUsageStore: ObservableObject {
    /// How long a report (or a failure) stands before opening the menu runs again.
    private static let staleAfter: TimeInterval = 30 * 60
    /// How old the archive may get before a run starts without the menu being
    /// opened, so months keep being saved on days the report isn't looked at.
    private static let archiveEvery: TimeInterval = 24 * 60 * 60

    @Published private(set) var report: CCUsageReport?
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private var lastAttemptAt: Date?
    /// When the archive on disk was last written; nil when there is none.
    private var archivedAt: Date?
    private var archiveTimer: Timer?

    init() {
        // What we saved last time, so the report has something to show
        // before ccusage has run.
        do {
            if let archive = try UsageHistory.load() {
                report = CCUsageReport(months: archive.months, generatedAt: archive.updatedAt)
                archivedAt = archive.updatedAt
            }
        } catch {
            DebugLog.log("usage history unreadable: \(error.localizedDescription)")
        }
        // An hourly look is cheap; the run it may start happens at most daily,
        // and not at launch, when the CPU has better things to do.
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.archiveIfDue() }
        }
    }

    private func archiveIfDue() {
        guard isAvailable else { return }
        if let archivedAt, Date().timeIntervalSince(archivedAt) < Self.archiveEvery { return }
        load()
    }

    var isAvailable: Bool { CCUsageCLI.isAvailable }

    /// One line for the menu: this month's spend, and the lifetime total.
    var menuSummary: String? {
        guard let report else { return nil }
        let total = Money.short(report.totals.totalCost)
        guard let month = report.currentMonth else { return "\(total) total" }
        return "\(Money.short(month.totalCost)) this month · \(total) total"
    }

    /// Called when the menu opens. Cheap unless the last attempt is old.
    func loadIfStale() {
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < Self.staleAfter { return }
        load()
    }

    /// Runs ccusage now, whatever the age of what we have.
    func load() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        lastAttemptAt = Date()

        Task { @MainActor in
            do {
                let fresh = try await CCUsageCLI.monthly()
                DebugLog.log("ccusage monthly: \(fresh.months.count) months")
                do {
                    let archive = try UsageHistory.merge(fresh.months)
                    archivedAt = archive.updatedAt
                    report = CCUsageReport(months: archive.months, generatedAt: fresh.generatedAt)
                } catch {
                    // Show the fresh run anyway; the archive is left as it was.
                    report = fresh
                    errorMessage = "Usage history not saved: \(error.localizedDescription)"
                    DebugLog.log("usage history not saved: \(error.localizedDescription)")
                }
            } catch {
                errorMessage = error.localizedDescription
                DebugLog.log("ccusage monthly failed: \(error.localizedDescription)")
            }
            isRunning = false
        }
    }
}

/// Dollar amounts, formatted the way ccusage prints them — the report is in US
/// dollars whatever the Mac's locale is.
enum Money {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    static func full(_ amount: Double) -> String {
        formatter.string(from: amount as NSNumber) ?? "$\(amount)"
    }

    /// No cents once the figure is big enough that they're noise.
    static func short(_ amount: Double) -> String {
        amount >= 100
            ? "$" + Tokens.grouped(Int(amount.rounded()))
            : full(amount)
    }
}

/// Token counts, grouped with commas like the ccusage table.
enum Tokens {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func grouped(_ count: Int) -> String {
        formatter.string(from: count as NSNumber) ?? "\(count)"
    }
}
