import SwiftUI

/// Sends bytes for keys a touch keyboard makes hard to reach: Ctrl-C, Tab, and Esc.
struct SoftKeyBar: View {
    enum Key: CaseIterable {
        case ctrlC
        case tab
        case esc

        var label: String {
            switch self {
            case .ctrlC: "Ctrl-C"
            case .tab: "Tab"
            case .esc: "Esc"
            }
        }

        var bytes: [UInt8] {
            switch self {
            case .ctrlC: [0x03]
            case .tab: [0x09]
            case .esc: [0x1B]
            }
        }
    }

    let onKey: (Key) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Key.allCases, id: \.self) { key in
                Button(key.label) {
                    onKey(key)
                }
                .buttonStyle(.bordered)
                .font(.system(.body, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
