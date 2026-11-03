import AppKit
import AISessionCore
import SwiftData
import SwiftUI
import XCTest
@testable import AI_Session_Remote

@MainActor
final class ConversationListLayoutTests: XCTestCase {
    func testNeedsYouRowKeepsAllThreeLinesAfterLiveStatusChanges() async throws {
        let model = AppModel(demo: true)
        let conversation = DemoFixtures.conversations[0]
        let store = model.store
        func show(_ conversations: [Conversation]) {
            store.seedForDemo(todos: DemoFixtures.todos, conversations: conversations,
                              sectionComputers: DemoFixtures.sectionComputers,
                              computers: DemoFixtures.computers)
        }
        show([])
        let container = try ModelContainer(for: HostEntity.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let host = NSHostingView(rootView:
            ConversationListView(filter: .constant(.needsYou), showsFilterPicker: false,
                                 showsShortcuts: true, selection: .constant(nil), onOpen: { _ in })
                .environment(model)
                .modelContainer(container)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 352, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
        }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await settle()
        for _ in 0..<3 {
            show([conversation])
            try await settle()
            let table = try XCTUnwrap(table(in: host))
            // The first section has a blank header followed by the conversation.
            XCTAssertEqual(table.numberOfRows, 4) // header, conversation, On hold header, drop area
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
            XCTAssertGreaterThanOrEqual(cell.fittingSize.height, DS.rowMinHeight)
            XCTAssertGreaterThanOrEqual(table.rect(ofRow: 1).height, cell.fittingSize.height,
                                        "A newly waiting conversation must not inherit a short section row's height")
            show([])
            try await settle()
        }
    }
}
