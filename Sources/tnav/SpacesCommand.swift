import Foundation
import TNavCore

/// Reports which Terminal tabs sit on the Space the user is currently looking at.
///
/// Exists because "focus worked" is only meaningful alongside "and the window was somewhere
/// else" — without this, a run where every window happened to be co-located looks identical
/// to proof of cross-Space focus.
enum SpacesCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let controller = AXWindowMenuController()
        let onCurrent = AXWindowMenuController.windowsOnCurrentSpace()

        // Every on-screen window, all apps — a fingerprint of "which desktop is showing".
        // Comparing Terminal's windows alone cannot tell a Space switch from a window being
        // dragged onto the current desktop, because the target ends up visible either way.
        if arguments.contains("--fingerprint") {
            let showing = AXWindowMenuController.applicationWindowsOnCurrentSpace()
            print(showing.sorted().map(String.init).joined(separator: "\n"))
            return 0
        }

        let ttys: [String]
        do {
            ttys = try controller.knownTTYs()
        } catch {
            printErr("\(error)")
            return 1
        }

        let machineReadable = arguments.contains("--porcelain")
        if !machineReadable {
            print("backend: \(AdaptiveTabController().activeBackend.rawValue)")
            print("accessibility: \(AXWindowMenuController.isPermitted ? "granted" : "NOT granted")")
            print("")
        }

        var here = 0
        for tty in ttys {
            guard let info = try? controller.windowInfo(forTTY: tty) else { continue }
            let isHere = onCurrent.contains(info.windowID)
            if isHere { here += 1 }
            if machineReadable {
                print("\(tty),\(info.windowID),\(isHere ? 1 : 0)")
            } else {
                print("  \(tty)  window=\(info.windowID)  "
                      + (isHere ? "this Space" : "another Space")
                      + "  '\(info.title)'")
            }
        }

        if !machineReadable {
            print("\n\(here) of \(ttys.count) tabs are on the Space you're looking at")
        }
        return 0
    }
}
