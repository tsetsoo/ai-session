import Foundation

/// Keeps text in the terminal's default colour readable on a background a program picked.
///
/// Codex asks the terminal for its background colour once, at startup, and tints its message
/// blocks to suit: a dark grey for a dark terminal. It never asks again. When the app later
/// switches to its light palette, those blocks keep the dark grey while the default text turns
/// dark, so the text vanishes. The guard follows SGR (`CSI … m`) in the output stream and, while
/// the default foreground sits on an explicit background it barely contrasts with, sets the
/// foreground to the palette's background colour instead. It undoes that as soon as the
/// background changes back.
///
/// Feed every output chunk through `process(_:)` in order; escape sequences may span chunks.
public struct TerminalContrastGuard {
    public typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    public struct Palette {
        public var foreground: RGB
        public var background: RGB
        /// The 16 ANSI colours: 8 normal, then 8 bright.
        public var ansi: [RGB]

        public init(foreground: RGB, background: RGB, ansi: [RGB]) {
            self.foreground = foreground
            self.background = background
            self.ansi = ansi
        }
    }

    /// Below this WCAG contrast ratio the default foreground counts as unreadable.
    static let minimumContrast = 3.0

    public private(set) var palette: Palette

    private enum Background: Equatable {
        case none
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    private var scanner = TerminalEscapeScanner()

    private struct Attributes {
        // What the program has asked for.
        var foregroundIsDefault = true
        var background = Background.none
        var inverse = false
        /// The foreground this guard set and the terminal still has, if any.
        var substitute: RGB?
    }

    private var attributes = Attributes()
    /// What `ESC 7` or `CSI ? 1049 h` saved with the cursor. The terminal restores it with
    /// `ESC 8` or `CSI ? 1049 l`, substitute included.
    private var saved = Attributes()

    public init(palette: Palette) {
        self.palette = palette
    }

    /// Switches palettes. Returns the SGR that brings the current foreground in line with the
    /// new palette, if it needs to change, to feed after everything already processed.
    public mutating func setPalette(_ palette: Palette) -> [UInt8]? {
        self.palette = palette
        return reconcile(touchedForeground: false)
    }

    /// Forgets the stream, for a new session on the same terminal. Returns `CSI 39 m` if the
    /// terminal still has a substitute foreground, so the new session doesn't inherit it.
    public mutating func reset() -> [UInt8]? {
        let hadSubstitute = attributes.substitute != nil
        self = TerminalContrastGuard(palette: palette)
        return hadSubstitute ? Array("\u{1B}[39m".utf8) : nil
    }

    /// Returns `bytes` with a foreground SGR added after each SGR that leaves default text
    /// unreadable, and a `CSI 39 m` after the one that makes it readable again.
    public mutating func process(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var copied = 0
        for (index, byte) in bytes.enumerated() {
            guard let insert = step(byte) else { continue }
            output.append(contentsOf: bytes[copied...index])
            output.append(contentsOf: insert)
            copied = index + 1
        }
        guard copied > 0 else { return bytes }
        output.append(contentsOf: bytes[copied...])
        return output
    }

    // MARK: - Parsing

    private mutating func step(_ byte: UInt8) -> [UInt8]? {
        switch scanner.step(byte) {
        case .escape(0x63): // c: RIS resets the attributes
            attributes = Attributes()
            saved = Attributes()
        case .escape(0x37): // 7: DECSC
            saved = attributes
        case .escape(0x38): // 8: DECRC
            attributes = saved
        case .csi(let csi):
            switch (csi.final, csi.marker, csi.intermediate) {
            case (0x6D, nil, nil): // m
                return applySGR(csi.params)
            case (0x70, nil, 0x21): // ! p: DECSTR resets the attributes
                attributes = Attributes()
            case (0x68, 0x3F, nil) where csi.numbers.contains(1049): // ? 1049 h saves the cursor
                saved = attributes
            case (0x6C, 0x3F, nil) where csi.numbers.contains(1049): // ? 1049 l restores it
                attributes = saved
            default:
                break
            }
        default:
            break
        }
        return nil
    }

    private mutating func applySGR(_ params: [UInt8]) -> [UInt8]? {
        // Split on `;`; a group may carry `:` sub-parameters (`38:2::r:g:b`).
        let groups = params.split(separator: 0x3B, omittingEmptySubsequences: false).map { group in
            group.split(separator: 0x3A, omittingEmptySubsequences: false).map(TerminalEscapeScanner.CSI.number)
        }
        var touchedForeground = false
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let code = group.first ?? 0
            switch code {
            case 0:
                attributes.foregroundIsDefault = true
                attributes.background = .none
                attributes.inverse = false
                touchedForeground = true
            case 7:
                attributes.inverse = true
            case 27:
                attributes.inverse = false
            case 30...37, 90...97:
                attributes.foregroundIsDefault = false
                touchedForeground = true
            case 39:
                attributes.foregroundIsDefault = true
                touchedForeground = true
            case 40...47:
                attributes.background = .indexed(UInt8(code - 40))
            case 100...107:
                attributes.background = .indexed(UInt8(code - 100 + 8))
            case 49:
                attributes.background = .none
            case 38, 48, 58: // 58 is the underline colour; its arguments are skipped
                let (color, used) = extendedColor(groups, at: index)
                index += used
                if code == 38 {
                    attributes.foregroundIsDefault = false
                    touchedForeground = true
                } else if code == 48, let color {
                    attributes.background = color
                }
            default:
                break
            }
            index += 1
        }
        return reconcile(touchedForeground: touchedForeground)
    }

    /// Reads `38`/`48` colour arguments starting at `groups[index]`. Returns the colour and how
    /// many extra `;` groups it consumed (none for the `:` form).
    private func extendedColor(_ groups: [[Int]], at index: Int) -> (Background?, Int) {
        let group = groups[index]
        if group.count > 1 {
            // Colon form: `48:5:n`, `48:2:r:g:b` or `48:2:colourspace:r:g:b`.
            let args = Array(group.dropFirst())
            switch args.first {
            case 5 where args.count >= 2: return (.indexed(clamp(args[1])), 0)
            case 2 where args.count >= 4:
                let rgb = args.count >= 5 ? Array(args.suffix(3)) : Array(args[1...3])
                return (.rgb(clamp(rgb[0]), clamp(rgb[1]), clamp(rgb[2])), 0)
            default: return (nil, 0)
            }
        }
        func arg(_ offset: Int) -> Int? {
            index + offset < groups.count ? groups[index + offset].first : nil
        }
        switch arg(1) {
        case 5:
            guard let n = arg(2) else { return (nil, groups.count - index - 1) }
            return (.indexed(clamp(n)), 2)
        case 2:
            guard let r = arg(2), let g = arg(3), let b = arg(4) else {
                return (nil, groups.count - index - 1)
            }
            return (.rgb(clamp(r), clamp(g), clamp(b)), 4)
        default:
            return (nil, 1)
        }
    }

    // MARK: - Contrast

    private mutating func reconcile(touchedForeground: Bool) -> [UInt8]? {
        // An SGR that sets or resets the foreground replaced whatever the guard had put there.
        if touchedForeground { attributes.substitute = nil }
        let wanted = wantedForeground()
        switch (attributes.substitute, wanted) {
        case (nil, nil):
            return nil
        case let (current?, wanted?) where current == wanted:
            return nil
        case (_, let wanted?):
            attributes.substitute = wanted
            return Array("\u{1B}[38;2;\(wanted.r);\(wanted.g);\(wanted.b)m".utf8)
        case (.some, nil):
            attributes.substitute = nil
            return Array("\u{1B}[39m".utf8)
        }
    }

    private func wantedForeground() -> RGB? {
        guard attributes.foregroundIsDefault, !attributes.inverse,
              let background = rgb(of: attributes.background) else { return nil }
        let current = Self.contrast(palette.foreground, background)
        guard current < Self.minimumContrast else { return nil }
        let alternative = palette.background
        return Self.contrast(alternative, background) > current ? alternative : nil
    }

    private func rgb(of background: Background) -> RGB? {
        switch background {
        case .none:
            return nil
        case let .rgb(r, g, b):
            return (r, g, b)
        case let .indexed(n) where n < 16:
            return n < palette.ansi.count ? palette.ansi[Int(n)] : nil
        case let .indexed(n) where n < 232:
            // The xterm 6×6×6 cube.
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let i = Int(n) - 16
            return (levels[i / 36], levels[(i / 6) % 6], levels[i % 6])
        case let .indexed(n):
            let level = UInt8(8 + (Int(n) - 232) * 10)
            return (level, level, level)
        }
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ c: RGB) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    // MARK: - Helpers

    private func clamp(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }
}
