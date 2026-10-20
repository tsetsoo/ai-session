import AISessionCore
import Foundation

/// Quick-add rules that don't need a view. The inline row in each section replaced the bar.
enum QuickAdd {
    /// `@AppStorage` key of the last section picked on the chip (its raw value).
    static let sectionKey = "quickAdd.section"

    /// The stored section, or I when nothing (or something unknown) is stored.
    static func section(from raw: String) -> TodoSection {
        TodoSection(rawValue: raw) ?? .i
    }

    /// What was typed before dictation started, then what was heard, with one space between.
    static func text(typed: String, dictated: String) -> String {
        guard !typed.isEmpty, !dictated.isEmpty else { return typed + dictated }
        return typed.hasSuffix(" ") ? typed + dictated : typed + " " + dictated
    }
}
