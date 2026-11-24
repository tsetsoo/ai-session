#if os(iOS) && canImport(ActivityKit)
import SwiftUI
import WidgetKit

@main
struct AISessionWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivityWidget()
    }
}
#endif
