import SwiftUI

/// The draft the person edits before a transcript that will not fit is sent. Cancel creates nothing.
struct DuplicateSummarySheet: View {
    @Binding var text: String
    var onStart: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .frame(minHeight: 240)
                .padding(DS.spacing.s)
                .navigationTitle("Summary")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start", action: onStart)
                    }
                }
        }
    }
}
