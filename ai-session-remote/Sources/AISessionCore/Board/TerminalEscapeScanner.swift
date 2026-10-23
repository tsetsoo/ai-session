/// Picks escape sequences out of terminal output one byte at a time. A sequence may span
/// chunks. OSC, DCS, APC, PM and SOS strings are skipped.
struct TerminalEscapeScanner {
    struct CSI {
        /// `?`, `>`, `<` or `=` before the parameters.
        var marker: UInt8?
        var intermediate: UInt8?
        /// Parameter bytes: digits, `;` and `:`.
        var params: [UInt8]
        var final: UInt8

        /// The `;`-separated parameters as numbers; `:` sub-parameters are dropped.
        var numbers: [Int] {
            params.split(separator: 0x3B, omittingEmptySubsequences: false).map {
                Self.number($0.prefix { $0 != 0x3A })
            }
        }

        static func number(_ digits: ArraySlice<UInt8>) -> Int {
            var value = 0
            for digit in digits where (0x30...0x39).contains(digit) {
                value = min(value * 10 + Int(digit - 0x30), 100_000)
            }
            return value
        }
    }

    enum Event {
        case csi(CSI)
        /// `ESC` and one final byte, such as `ESC 7` or `ESC c`.
        case escape(UInt8)
    }

    private enum State {
        case ground, escape, csi, string
    }

    private var state = State.ground
    private var csi = CSI(params: [], final: 0)
    private var csiIgnored = false
    private var stringIsOSC = false

    mutating func step(_ byte: UInt8) -> Event? {
        switch state {
        case .ground:
            if byte == 0x1B { state = .escape }
        case .escape:
            switch byte {
            case 0x5B: // [
                state = .csi
                csi = CSI(params: [], final: 0)
                csiIgnored = false
            case 0x5D, 0x50, 0x5F, 0x5E, 0x58: // ] P _ ^ X
                state = .string
                stringIsOSC = byte == 0x5D
            case 0x1B:
                break
            case 0x30...0x7E:
                state = .ground
                return .escape(byte)
            default:
                state = .ground
            }
        case .csi:
            switch byte {
            case 0x30...0x3F:
                if (0x3C...0x3F).contains(byte), csi.params.isEmpty, csi.marker == nil {
                    csi.marker = byte
                } else if csi.params.count < 128 {
                    csi.params.append(byte)
                } else {
                    csiIgnored = true
                }
            case 0x20...0x2F:
                if csi.intermediate == nil { csi.intermediate = byte } else { csiIgnored = true }
            case 0x40...0x7E:
                state = .ground
                guard !csiIgnored else { return nil }
                csi.final = byte
                return .csi(csi)
            case 0x1B:
                state = .escape
            case 0x18, 0x1A: // CAN, SUB
                state = .ground
            default:
                break
            }
        case .string:
            if byte == 0x1B {
                state = .escape
            } else if byte == 0x07, stringIsOSC {
                state = .ground
            }
        }
        return nil
    }
}
