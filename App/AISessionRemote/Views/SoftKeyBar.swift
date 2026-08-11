import SwiftUI

/// Always-available keys when the software keyboard (and SwiftTerm accessory) are hidden.
struct SoftKeyBar: View {
    enum Key: CaseIterable, Identifiable {
        case ctrlC
        case tab
        case esc
        case paste

        var id: Self { self }

        var label: String {
            switch self {
            case .ctrlC: "Ctrl-C"
            case .tab: "Tab"
            case .esc: "Esc"
            case .paste: "Paste"
            }
        }
    }

    let onKey: (Key) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Key.allCases) { key in
                    Button(key.label) {
                        onKey(key)
                    }
                    .buttonStyle(.bordered)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .tint(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.92))
    }
}
