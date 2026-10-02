import AppKit
import SwiftUI

/// The window the "Monthly report" menu item opens. Built once and reused, so
/// closing it keeps whatever ccusage last reported.
@MainActor
final class MonthlyReportWindow {
    private let store: CCUsageStore
    private var window: NSWindow?

    init(store: CCUsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Monthly spend — ccusage"
            window.contentView = NSHostingView(rootView: MonthlyReportView(store: store))
            // We're an accessory app with nothing else to hold the window.
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        // An accessory app has to ask, or the window opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // Opening it is also a request for figures, if there are none yet.
        if store.report == nil { store.load() } else { store.loadIfStale() }
    }
}

private struct MonthlyReportView: View {
    @ObservedObject var store: CCUsageStore
    /// Months whose per-model breakdown is showing.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = store.report {
                ReportTable(report: report, expanded: $expanded)
            } else {
                placeholder
            }
        }
        .frame(minWidth: Column.minimumWidth, minHeight: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spend across every agent ccusage finds logs for")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRunning {
                ProgressView().controlSize(.small)
            }
            Button(store.report == nil ? "Run ccusage" : "Refresh") { store.load() }
                .disabled(store.isRunning)
        }
        .padding(.horizontal, Column.padding)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if store.isRunning { return "Running bunx ccusage monthly…" }
        if let error = store.errorMessage { return error }
        guard let report = store.report else { return "bunx ccusage monthly" }
        let when = report.generatedAt.formatted(date: .omitted, time: .shortened)
        let unpriced = report.totals.unpricedModels ?? []
        let note = unpriced.isEmpty
            ? ""
            : " · no pricing for \(unpriced.joined(separator: ", ")), so the cost is short"
        return "Read at \(when)\(note)"
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if store.isRunning {
                ProgressView()
                Text("Reading every agent's logs — this takes a few seconds.")
                    .foregroundStyle(.secondary)
            } else if let error = store.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            } else if !store.isAvailable {
                Text("bunx not found. Install bun, then run ccusage from here.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing read yet.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Column widths, shared by the head, the rows and the totals line so the three
/// stay lined up. `minimumWidth` keeps the window from squeezing them: the head
/// and the totals sit outside the scroll view and would be shoved off-centre.
private enum Column {
    static let name: CGFloat = 200
    static let cost: CGFloat = 92
    static let total: CGFloat = 116
    static let input: CGFloat = 96
    static let output: CGFloat = 96
    static let cacheWrite: CGFloat = 104
    static let cacheRead: CGFloat = 116
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16

    static var minimumWidth: CGFloat {
        name + cost + total + input + output + cacheWrite + cacheRead + 6 * spacing + 2 * padding
    }
}

private struct ReportTable: View {
    let report: CCUsageReport
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            headRow
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(report.months) { month in
                        MonthRow(month: month,
                                 isExpanded: expanded.contains(month.id),
                                 toggle: { toggle(month.id) })
                        if expanded.contains(month.id) {
                            ForEach(month.modelBreakdowns.sorted { $0.cost > $1.cost }) { model in
                                ModelRow(model: model)
                            }
                        }
                        Divider()
                    }
                }
            }
            Divider()
            totalsRow
        }
    }

    private func toggle(_ period: String) {
        if expanded.contains(period) { expanded.remove(period) } else { expanded.insert(period) }
    }

    private var headRow: some View {
        HStack(spacing: Column.spacing) {
            Text("Month").frame(width: Column.name, alignment: .leading)
            Text("Cost").frame(width: Column.cost, alignment: .trailing)
            Text("Tokens").frame(width: Column.total, alignment: .trailing)
            Text("Input").frame(width: Column.input, alignment: .trailing)
            Text("Output").frame(width: Column.output, alignment: .trailing)
            Text("Cache write").frame(width: Column.cacheWrite, alignment: .trailing)
            Text("Cache read").frame(width: Column.cacheRead, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Column.padding)
        .padding(.vertical, 6)
    }

    private var totalsRow: some View {
        let totals = report.totals
        return HStack(spacing: Column.spacing) {
            Text("Total").frame(width: Column.name, alignment: .leading)
            Text(Money.full(totals.totalCost)).frame(width: Column.cost, alignment: .trailing)
            Text(Tokens.grouped(totals.totalTokens)).frame(width: Column.total, alignment: .trailing)
            Text(Tokens.grouped(totals.inputTokens)).frame(width: Column.input, alignment: .trailing)
            Text(Tokens.grouped(totals.outputTokens)).frame(width: Column.output, alignment: .trailing)
            Text(Tokens.grouped(totals.cacheCreationTokens)).frame(width: Column.cacheWrite, alignment: .trailing)
            Text(Tokens.grouped(totals.cacheReadTokens)).frame(width: Column.cacheRead, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .padding(.horizontal, Column.padding)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
}

private struct MonthRow: View {
    let month: CCUsageReport.Month
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Column.spacing) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(month.period).font(.system(size: 12, weight: .semibold))
                        if !month.agents.isEmpty {
                            Text(month.agents.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: Column.name, alignment: .leading)

                Text(Money.full(month.totalCost)).frame(width: Column.cost, alignment: .trailing)
                Text(Tokens.grouped(month.totalTokens)).frame(width: Column.total, alignment: .trailing)
                Text(Tokens.grouped(month.inputTokens)).frame(width: Column.input, alignment: .trailing)
                Text(Tokens.grouped(month.outputTokens)).frame(width: Column.output, alignment: .trailing)
                Text(Tokens.grouped(month.cacheCreationTokens)).frame(width: Column.cacheWrite, alignment: .trailing)
                Text(Tokens.grouped(month.cacheReadTokens)).frame(width: Column.cacheRead, alignment: .trailing)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12).monospacedDigit())
            .padding(.horizontal, Column.padding)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the models behind \(month.period)")
    }
}

private struct ModelRow: View {
    let model: CCUsageReport.Model

    var body: some View {
        HStack(spacing: Column.spacing) {
            Text(model.missingPricing == true ? "\(model.modelName) (unpriced)" : model.modelName)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 20)
                .frame(width: Column.name, alignment: .leading)
            Text(Money.full(model.cost)).frame(width: Column.cost, alignment: .trailing)
            Text(Tokens.grouped(model.totalTokens)).frame(width: Column.total, alignment: .trailing)
            Text(Tokens.grouped(model.inputTokens)).frame(width: Column.input, alignment: .trailing)
            Text(Tokens.grouped(model.outputTokens)).frame(width: Column.output, alignment: .trailing)
            Text(Tokens.grouped(model.cacheCreationTokens)).frame(width: Column.cacheWrite, alignment: .trailing)
            Text(Tokens.grouped(model.cacheReadTokens)).frame(width: Column.cacheRead, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, Column.padding)
        .padding(.vertical, 2)
    }
}
