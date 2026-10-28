#if os(iOS)
import SwiftUI
import UIKit

/// Native selection handles and the standard Copy menu, with a height that reflows at the
/// phone's width and Dynamic Type size. Its backing string is the unmodified message.
struct ChatMessageText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text || view.font != UIFont.preferredFont(forTextStyle: .body) else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

@MainActor
final class ChatDraftEditorHandle {
    weak var view: UITextView?

    /// UITextInput replaces the selected range and inserts at the caret, just like the
    /// system Paste menu. Appending to a SwiftUI binding would always paste at the end.
    func insert(_ text: String) {
        view?.insertText(text)
        view?.becomeFirstResponder()
    }
}

struct ChatDraftEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let handle: ChatDraftEditorHandle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = "Message. Return adds a new line."
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handle.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if focused, !view.isFirstResponder { view.becomeFirstResponder() }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(180, max(64, size.height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatDraftEditor
        init(_ parent: ChatDraftEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    }
}
#endif
