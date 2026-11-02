import SwiftUI
import UIKit

@main
struct EWPApp: App {
    init() {
        // A device on the wall has nobody to wake it. Letting the screen lock
        // suspends the app, which takes the MCP endpoint and the Bluetooth
        // scan down with it, and an agent sees a device that simply stopped
        // answering.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            CompanionView().tint(Theme.accent)
        }
    }
}
