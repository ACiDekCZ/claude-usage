import AppKit
import Combine

/// Owns the menu bar item.
///
/// This is plain AppKit rather than SwiftUI's `MenuBarExtra`: that view only
/// accepts `Text` and symbol images in its label, drops a rendered `NSImage`
/// entirely, and strips tint from text — so there is no way to colour the
/// title through it. `NSStatusItem.button.attributedTitle` colours reliably.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// The settings page the figures come from, for opening in the real browser.
    private let usagePageURL = URL(string: "https://claude.ai/new#settings/usage")!

    private var statusItem: NSStatusItem!
    private var usageManager: UsageManager!
    private var keepAwake: KeepAwake!
    private var ccusage: CCUsageStore!
    private var monthlyReport: MonthlyReportWindow!
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = UsageManager()
        usageManager = manager
        keepAwake = KeepAwake()
        let ccusageStore = CCUsageStore()
        ccusage = ccusageStore
        monthlyReport = MonthlyReportWindow(store: ccusageStore)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        // objectWillChange fires before the value lands, so hop a runloop turn.
        cancellable = manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusItem() }

        updateStatusItem()
    }

    // MARK: - Menu bar title

    private func updateStatusItem() {
        guard let button = statusItem.button, let manager = usageManager else { return }

        // A read takes seconds; the figures stay up through it, so the symbol
        // is what carries the state — a warning triangle once they go stale.
        let symbol: String
        if !manager.autoRefresh {
            symbol = "pause.circle"
        } else if manager.isStale {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "sparkle"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude usage")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        // Old figures are still worth showing, just not at full strength.
        // Fresh ones are left exactly as they are — the system label colours
        // carry an alpha of their own, and forcing it to 1 blackens them.
        func tinted(_ color: NSColor) -> NSColor {
            manager.isStale ? color.withAlphaComponent(0.45) : color
        }

        // Only the deviation carries the colour — weekly usage is just a fact,
        // it's the distance from today's budget that is good or bad.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString(
            string: " " + manager.displayPrimary,
            attributes: [.font: font,
                         .foregroundColor: tinted(manager.displayPrimaryStatus.color)]
        )
        if let pace = manager.displayPace {
            title.append(NSAttributedString(
                string: "·",
                attributes: [.font: font,
                             .foregroundColor: tinted(.tertiaryLabelColor)]
            ))
            title.append(NSAttributedString(
                string: pace,
                attributes: [.font: font,
                             .foregroundColor: tinted(manager.displayStatus.color)]
            ))
        }
        button.attributedTitle = title

        button.toolTip = manager.displayPace == nil
            ? "Claude usage"
            : "Weekly used · share of the week elapsed (where you should be) — \(manager.displayStatus.label). \(Self.freshness(manager))"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let manager = usageManager else { return }

        // Opening the menu is what sets ccusage going — it's too expensive to
        // run on a timer, and this is the moment the figures are wanted.
        ccusage.loadIfStale()

        if manager.isLoggedIn, let usage = manager.usageData, let all = usage.allModelsPercent {
            addPaceSection(to: menu, usage: usage, all: all)
            addWeeklySection(to: menu, usage: usage, all: all)
            addSessionSection(to: menu, usage: usage)

            menu.addItem(.separator())

            menu.addItem(infoItem(Self.freshness(manager), small: true))
            let toggle = actionItem("Auto-refresh", #selector(toggleAutoRefresh))
            toggle.state = manager.autoRefresh ? .on : .off
            menu.addItem(toggle)
            menu.addItem(actionItem("Refresh", #selector(refresh), key: "r"))
            menu.addItem(.separator())
            menu.addItem(actionItem("Logout", #selector(logout)))
        } else {
            menu.addItem(infoItem(manager.errorMessage ?? "Loading…", small: true))
            menu.addItem(.separator())
            menu.addItem(actionItem("Import from Chrome", #selector(importFromChrome)))
            menu.addItem(actionItem("Login in WebView…", #selector(showLogin)))
            menu.addItem(actionItem("Refresh", #selector(refresh), key: "r"))
        }

        addSpendSection(to: menu)

        menu.addItem(.separator())
        let awake = actionItem("Keep Mac awake (displays may sleep)", #selector(toggleKeepAwake))
        awake.state = keepAwake.isOn ? .on : .off
        menu.addItem(awake)

        menu.addItem(.separator())
        menu.addItem(actionItem("Open usage page in browser", #selector(openUsagePage), key: "o"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", #selector(quit), key: "q"))
    }

    /// The headline: how today's spending compares to the day's slice of the weekly limit.
    private func addPaceSection(to menu: NSMenu, usage: UsageData, all: Double) {
        guard let expected = usage.expectedPercent,
              let ahead = usage.dayDeviationPercent,
              let day = usage.weekDayIndex else { return }

        menu.addItem(infoItem(String(format: "%@  %d%% used · %.1f%% of the week gone",
                                     usage.paceStatus.dot, Int(all), expected),
                              color: usage.paceStatus.color, bold: true))

        // The colour comes from this distance, so spell it out.
        let verdict = ahead > 0
            ? String(format: "%.1f%% ahead of the line", ahead)
            : String(format: "%.1f%% behind the line", -ahead)
        menu.addItem(infoItem(verdict, small: true))
        menu.addItem(infoItem(String(format: "Day %d/7, %.0f%% into the day", day, usage.dayProgressPercent ?? 0),
                              small: true))
        menu.addItem(infoItem(String(format: "Orange once ahead, red past +%.0f%%, green at −%.1f%% (a day in hand)",
                                     3.0, dailyAllowancePercent),
                              small: true))
        menu.addItem(.separator())
    }

    private func addWeeklySection(to menu: NSMenu, usage: UsageData, all: Double) {
        menu.addItem(infoItem("Weekly (all models): \(Int(all))% used", bold: true))
        if let resetDate = usage.allModelsResetDate {
            menu.addItem(infoItem("Resets \(UsageManager.absoluteReset(resetDate)) · in \(UsageManager.compactDuration(resetDate.timeIntervalSince(Date())))",
                                  small: true))
        } else if let reset = usage.allModelsReset {
            menu.addItem(infoItem("Resets \(reset)", small: true))
        }
        if let timePct = usage.allModelsTimePercent {
            menu.addItem(infoItem("Week elapsed: \(Int(timePct))%", small: true))
        }
        menu.addItem(.separator())
    }

    private func addSessionSection(to menu: NSMenu, usage: UsageData) {
        if let current = usage.currentSessionPercent {
            menu.addItem(infoItem("Session: \(Int(current))% used", bold: true))
            if let resetDate = usage.currentSessionResetDate {
                menu.addItem(infoItem("Resets \(UsageManager.absoluteReset(resetDate)) · in \(UsageManager.compactDuration(resetDate.timeIntervalSince(Date())))",
                                      small: true))
            } else if let reset = usage.currentSessionReset {
                menu.addItem(infoItem("Resets \(reset)", small: true))
            }
        }
        if let other = usage.sonnetPercent, other > 0 {
            menu.addItem(infoItem("\(usage.sonnetLabel ?? "Sonnet"): \(Int(other))%", small: true))
        }
    }

    /// How old the figures on screen are — they stay up while the next read
    /// runs, so the menu has to say which it is.
    private static func freshness(_ manager: UsageManager) -> String {
        if manager.isFetching { return "Refreshing…" }
        guard let lastUpdate = manager.lastUpdate else { return "Not read yet" }
        let age = Date().timeIntervalSince(lastUpdate)
        if age < 60 { return "Read just now" }
        return "Read \(UsageManager.compactDuration(age)) ago"
    }

    /// Dollar spend from `bunx ccusage monthly`, with the window behind it.
    private func addSpendSection(to menu: NSMenu) {
        menu.addItem(.separator())
        if let summary = ccusage.menuSummary {
            menu.addItem(infoItem(summary, bold: true))
            if ccusage.isRunning {
                menu.addItem(infoItem("Refreshing…", small: true))
            }
        } else if ccusage.isRunning {
            menu.addItem(infoItem("Reading ccusage…", small: true))
        } else if let error = ccusage.errorMessage {
            menu.addItem(infoItem(error, small: true))
        }
        menu.addItem(actionItem("Monthly report…", #selector(showMonthlyReport), key: "m"))
    }

    // MARK: - Item builders

    /// A non-interactive row. Kept "enabled" (with `autoenablesItems = false`)
    /// so AppKit doesn't grey out the colour we set.
    private func infoItem(_ text: String,
                          color: NSColor? = nil,
                          bold: Bool = false,
                          small: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let font: NSFont = small
            ? .menuFont(ofSize: NSFont.smallSystemFontSize)
            : (bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .menuFont(ofSize: 0))
        let resolved = color ?? (small ? NSColor.secondaryLabelColor : NSColor.labelColor)
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: resolved]
        )
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func refresh() { usageManager.fetchUsage() }
    @objc private func toggleAutoRefresh() { usageManager.toggleAutoRefresh() }
    @objc private func logout() { usageManager.logout() }
    @objc private func importFromChrome() { usageManager.importFromChrome() }
    @objc private func showLogin() { usageManager.showLogin() }
    @objc private func toggleKeepAwake() { keepAwake.toggle() }
    @objc private func showMonthlyReport() { monthlyReport.show() }
    @objc private func openUsagePage() { NSWorkspace.shared.open(usagePageURL) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
