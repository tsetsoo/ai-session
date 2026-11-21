import AISessionCore
import Foundation

/// Quick-add rules that don't need a view. The inline row in each section replaced the bar.
enum QuickAdd {
    /// What was typed before dictation started, then what was heard, with one space between.
    static func text(typed: String, dictated: String) -> String {
        guard !typed.isEmpty, !dictated.isEmpty else { return typed + dictated }
        return typed.hasSuffix(" ") ? typed + dictated : typed + " " + dictated
    }
}
