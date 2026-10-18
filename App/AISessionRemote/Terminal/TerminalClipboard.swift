import Foundation

/// Text from an OSC 52 clipboard write.
///
/// SwiftTerm base64-decodes the sequence and passes the raw bytes here. A payload that is
/// not UTF-8 is rejected so it cannot clear the local pasteboard. An empty string is the
/// session asking to clear it.
enum TerminalClipboard {
    static func pasteboardText(from content: Data) -> String? {
        String(data: content, encoding: .utf8)
    }
}
