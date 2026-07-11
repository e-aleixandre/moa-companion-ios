import SwiftUI
import MoaOpsCore
import MoaOpsPresentation

@main
struct MoaCompanionApp: App {
    @StateObject private var ops = MoaOpsAppModel()

    var body: some Scene {
        WindowGroup {
            MoaOpsRootView(model: ops)
        }
    }
}
