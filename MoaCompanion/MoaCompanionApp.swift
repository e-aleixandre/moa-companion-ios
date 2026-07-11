import SwiftUI
import MoaOpsCore
import MoaOpsPresentation

@main
struct MoaCompanionApp: App {
    @StateObject private var companion = MoaCompanionAppModel()

    var body: some Scene {
        WindowGroup {
            MoaCompanionRootView(model: companion)
        }
    }
}
