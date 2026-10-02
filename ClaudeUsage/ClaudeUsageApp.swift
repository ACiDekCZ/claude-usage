import SwiftUI

@main
struct ClaudeUsageApp: App {
    // The menu bar item is built in AppKit — see StatusItemController.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
