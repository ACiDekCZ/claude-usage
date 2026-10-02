import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while letting the displays sleep — the same as
/// `caffeinate -ims` (no `-d`). The assertions die with the process, so a
/// crash can't leave the Mac unable to sleep.
///
/// The choice is remembered and re-applied on launch.
@MainActor
final class KeepAwake {
    private static let defaultsKey = "keepAwake"

    /// Idle sleep, sleep on AC power, and disk idle — the display assertion
    /// is deliberately left out.
    private static let assertionTypes = [
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventSystemSleep,
        "PreventDiskIdle"
    ]

    private var assertionIDs: [IOPMAssertionID] = []

    var isOn: Bool { !assertionIDs.isEmpty }

    init() {
        if UserDefaults.standard.bool(forKey: Self.defaultsKey) {
            enable()
        }
    }

    func toggle() {
        if isOn { disable() } else { enable() }
        UserDefaults.standard.set(isOn, forKey: Self.defaultsKey)
    }

    private func enable() {
        guard !isOn else { return }
        for type in Self.assertionTypes {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ClaudeUsage: keep Mac awake, displays may sleep" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionIDs.append(id)
            } else {
                DebugLog.log("KeepAwake: \(type) assertion failed (\(result))")
            }
        }
    }

    private func disable() {
        assertionIDs.forEach { IOPMAssertionRelease($0) }
        assertionIDs.removeAll()
    }
}
