import SwiftUI

@main
struct EWPApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionView().tint(Theme.accent)
        }
    }
}
