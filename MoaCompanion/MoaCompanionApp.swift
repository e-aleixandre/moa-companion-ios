import SwiftUI
import MoaOpsCore
import MoaOpsPresentation

@main
struct MoaCompanionApp: App {
    @StateObject private var pulse = PulseCallAppModel()

    var body: some Scene {
        WindowGroup {
            PulseCallRootView(model: pulse)
        }
    }
}
