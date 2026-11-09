import Foundation

struct ClaudeCLIUsageWindow: Sendable, Equatable {
    let usedPercent: Double
    let resetDescription: String?
}

struct ClaudeCLIUsageNamedWindow: Sendable, Equatable {
    let title: String
    let window: ClaudeCLIUsageWindow
}

struct ClaudeCLIUsageReading: Sendable, Equatable {
    let fiveHour: ClaudeCLIUsageWindow?
    let weekly: ClaudeCLIUsageWindow?
    let modelWindows: [ClaudeCLIUsageNamedWindow]
}

enum ClaudeCLIUsageParserError: Error, Sendable, Equatable {
    case loading
    case unavailable
    case invalidOutput
}

struct ClaudeCLIUsageParser {
    static func parse(screen: String) throws -> ClaudeCLIUsageReading {
        guard screen.utf8.count <= 1_000_000 else { throw ClaudeCLIUsageParserError.invalidOutput }
        let lines = screen.components(separatedBy: .newlines)
        if lines.contains(where: {
            $0.localizedCaseInsensitiveContains("Error: Failed to load usage data")
                || $0.localizedCaseInsensitiveContains("Showing last-known usage")
                || $0.localizedCaseInsensitiveContains("could not refresh")
        }) {
            // Claude can display a seeded, cached panel after a failed request.
            // Never give that old measurement a fresh capture timestamp.
            throw ClaudeCLIUsageParserError.unavailable
        }
        if lines.contains(where: { $0.localizedCaseInsensitiveContains("Refreshing") || $0.localizedCaseInsensitiveContains("Loading") }) {
            throw ClaudeCLIUsageParserError.loading
        }
        var sections: [(kind: String, title: String, lines: [String])] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isInsightsHeading(t) { break }
            if t.localizedCaseInsensitiveContains("error:") { throw ClaudeCLIUsageParserError.unavailable }
            if t == "Current session" { sections.append(("session", "", [])) }
            else if t == "Current week" || t == "Current week (all models)" { sections.append(("week", "", [])) }
            else if t.hasPrefix("Current week (") && t.hasSuffix(")") {
                let title = String(t.dropFirst("Current week (".count).dropLast())
                guard title.utf8.count <= 200 else { throw ClaudeCLIUsageParserError.invalidOutput }
                sections.append(("model", title, []))
            } else if !sections.isEmpty { sections[sections.count - 1].lines.append(line) }
        }
        guard sections.count <= 100 else { throw ClaudeCLIUsageParserError.invalidOutput }
        guard !sections.isEmpty else { throw ClaudeCLIUsageParserError.unavailable }
        func window(_ section: (kind: String, title: String, lines: [String])) throws -> ClaudeCLIUsageWindow? {
            let text = section.lines.joined(separator: "\n")
            guard text.utf8.count <= 20_000 else { throw ClaudeCLIUsageParserError.invalidOutput }
            let pattern = #"(?i)([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*%\s*(used|left)\b"#
            let regex = try! NSRegularExpression(pattern: pattern)
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            var values: [Double] = []
            for match in matches {
                guard let value = Double(ns.substring(with: match.range(at: 1))), value >= 0, value <= 100 else {
                    throw ClaudeCLIUsageParserError.invalidOutput
                }
                let mode = ns.substring(with: match.range(at: 2)).lowercased()
                values.append(mode == "left" ? 100 - value : value)
            }
            // A percentage-shaped value without a recognized used/left label is malformed, not a guess.
            if matches.isEmpty && text.range(of: #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)\s*%"#, options: .regularExpression) != nil {
                throw ClaudeCLIUsageParserError.invalidOutput
            }
            guard let first = values.first else { return nil }
            guard values.allSatisfy({ $0 == first }) else { throw ClaudeCLIUsageParserError.invalidOutput }
            let resets = section.lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in line.range(of: #"(?i)\b(reset|resets|resetting|ends|renews)\b"#, options: .regularExpression) != nil }
            guard resets.allSatisfy({ $0.utf8.count <= 200 }) else { throw ClaudeCLIUsageParserError.invalidOutput }
            return ClaudeCLIUsageWindow(usedPercent: first, resetDescription: resets.first)
        }
        var session: ClaudeCLIUsageWindow?, weekly: ClaudeCLIUsageWindow?
        var sawSession = false, sawWeek = false
        var models: [ClaudeCLIUsageNamedWindow] = []
        for section in sections {
            let value = try window(section)
            if section.kind == "session" {
                guard !sawSession || session == value else { throw ClaudeCLIUsageParserError.invalidOutput }
                sawSession = true; session = value
            }
            if section.kind == "week" {
                guard !sawWeek || weekly == value else { throw ClaudeCLIUsageParserError.invalidOutput }
                sawWeek = true; weekly = value
            }
            if section.kind == "model", let value {
                if let prior = models.first(where: { $0.title == section.title }), prior.window != value {
                    throw ClaudeCLIUsageParserError.invalidOutput
                }
                if !models.contains(where: { $0.title == section.title }) { models.append(ClaudeCLIUsageNamedWindow(title: section.title, window: value)) }
            }
        }
        guard session != nil || weekly != nil else { throw ClaudeCLIUsageParserError.unavailable }
        return ClaudeCLIUsageReading(fiveHour: session, weekly: weekly, modelWindows: models)
    }

    private static func isInsightsHeading(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.range(of: #"(?i)^what's contributing to your (?:limits )?usage\?.*$"#, options: .regularExpression) != nil
    }
}

/// Small bounded screen model for already-rendered terminal text; it is not a full VT emulator.
struct ClaudeCLITerminalScreen {
    private var cells: [[String]]
    private var row = 0, column = 0, savedRow = 0, savedColumn = 0
    private var wrapPending = false
    private var state = 0 // ground, ESC, CSI, OSC, OSC-after-ESC
    private var control = [UInt8]()
    private var utf8 = [UInt8]()
    private let columns: Int
    private let rows: Int

    init(columns: Int = 160, rows: Int = 200) {
        self.columns = min(500, max(1, columns)); self.rows = min(500, max(1, rows))
        cells = Array(repeating: Array(repeating: " ", count: min(500, max(1, columns))), count: min(500, max(1, rows)))
    }

    var text: String { cells.map { $0.joined().trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }

    mutating func append(_ data: Data) {
        for byte in data {
            if state != 0 { consumeControl(byte); continue }
            if byte == 0x1b { flushUTF8(); state = 1; continue }
            if byte < 0x20 || byte == 0x7f {
                flushUTF8()
                switch byte {
                case 0x0a: advanceRow(); wrapPending = false
                case 0x0d: column = 0; wrapPending = false
                case 0x08: column = max(0, column - 1)
                case 0x09: column = min(columns - 1, ((column / 8) + 1) * 8)
                default: break
                }
                continue
            }
            utf8.append(byte); flushUTF8(incompleteOK: true)
        }
    }

    private mutating func flushUTF8(incompleteOK: Bool = false) {
        while !utf8.isEmpty {
            let b = utf8[0], n = b < 0x80 ? 1 : (b & 0xE0 == 0xC0 ? 2 : (b & 0xF0 == 0xE0 ? 3 : (b & 0xF8 == 0xF0 ? 4 : 1)))
            if utf8.count < n && incompleteOK { return }
            let count = min(n, utf8.count)
            let s = String(bytes: utf8.prefix(count), encoding: .utf8) ?? "�"
            put(s); utf8.removeFirst(count)
        }
    }
    private mutating func put(_ s: String) {
        guard row >= 0 && row < rows else { return }
        if wrapPending { column = 0; advanceRow(); wrapPending = false }
        if column >= columns { column = columns - 1 }
        let scalars = s.unicodeScalars
        if scalars.allSatisfy({ [.nonspacingMark, .enclosingMark, .format].contains($0.properties.generalCategory) }) {
            let prior = wrapPending ? column : column - 1
            if prior >= 0 {
                let start = cells[row][prior].isEmpty && prior > 0 ? prior - 1 : prior
                cells[row][start] += s
            }
            return
        }
        let wide = scalars.contains(where: { $0.properties.isEmojiPresentation }) || scalars.contains(where: {
            (0x1100...0x115f).contains($0.value) || (0x2e80...0xa4cf).contains($0.value)
                || (0xac00...0xd7a3).contains($0.value) || (0xf900...0xfaff).contains($0.value)
                || (0xfe10...0xfe6f).contains($0.value) || (0xff00...0xff60).contains($0.value)
                || (0xffe0...0xffe6).contains($0.value) || (0x20000...0x3fffd).contains($0.value)
        })
        let width = wide && columns > 1 ? 2 : 1
        if column + width > columns { column = 0; advanceRow() }
        clearCell(row, column)
        if width == 2 { clearCell(row, column + 1) }
        cells[row][column] = s
        if width == 2 { cells[row][column + 1] = "" }
        if column + width >= columns { column = columns - 1; wrapPending = true }
        else { column += width }
    }
    private mutating func clearCell(_ r: Int, _ c: Int) {
        if cells[r][c].isEmpty, c > 0 { cells[r][c - 1] = " " }
        if c + 1 < columns, cells[r][c + 1].isEmpty { cells[r][c + 1] = " " }
        cells[r][c] = " "
    }
    private mutating func advanceRow() {
        if row < rows - 1 { row += 1 }
        else { cells.removeFirst(); cells.append(Array(repeating: " ", count: columns)) }
    }
    private mutating func consumeControl(_ b: UInt8) {
        switch state {
        case 1:
            control.removeAll()
            if b == 0x5b { state = 2 }
            else if [0x5d, 0x50, 0x5e, 0x5f].contains(b) { state = 3 }
            else {
                switch b {
                case 0x37: savedRow = row; savedColumn = column
                case 0x38: row = savedRow; column = savedColumn; wrapPending = false
                case 0x44: advanceRow(); wrapPending = false
                case 0x45: column = 0; advanceRow(); wrapPending = false
                case 0x3d, 0x3e: break // keypad modes do not change cells
                default:
                    // Includes RIS (ESC c). An unknown display operation cannot
                    // leave a previous panel available for a fresh measurement.
                    cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
                    row = 0; column = 0; savedRow = 0; savedColumn = 0; wrapPending = false
                }
                state = 0
            }
        case 2:
            control.append(b)
            if b >= 0x40 && b <= 0x7e { executeCSI(final: b); control.removeAll(); state = 0 }
            else if control.count > 64 { control.removeAll(); state = 0 }
        case 3: if b == 7 { state = 0 } else if b == 0x1b { state = 4 }
        case 4: state = b == 0x5c ? 0 : 3
        default: state = 0
        }
    }
    private mutating func executeCSI(final: UInt8) {
        let raw = String(decoding: control.dropLast(), as: UTF8.self)
        if raw.first == "?" {
            // Cursor visibility, bracketed paste, synchronized redraw and mouse
            // modes do not erase text. Claude toggles these around every frame.
            let modes = raw.dropFirst().split(separator: ";").compactMap { Int($0) }
            if (final == 0x68 || final == 0x6c), modes.contains(where: { [47, 1047, 1049].contains($0) }) {
                cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
                row = 0; column = 0; wrapPending = false
            }
            return
        }
        if final == 0x6d { return } // SGR, including colon-form colours, changes no cells
        // Device/status queries, cursor style and Kitty keyboard protocol push/
        // pop do not alter displayed cells. In particular Claude emits CSI < u
        // after panel redraws; treating it as an erase loses the quota rows.
        if [0x63, 0x6e, 0x71].contains(final) { return }
        if final == 0x75, raw.first == ">" || raw.first == "<" { return }
        guard raw.utf8.allSatisfy({ (48...57).contains($0) || $0 == 59 }) else {
            cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
            row = 0; column = 0; wrapPending = false
            return
        }
        let fields = raw.split(separator: ";", omittingEmptySubsequences: false).map { part -> Int in
            guard !part.isEmpty, part.utf8.count <= 9, let n = Int(part), n <= 100_000 else { return 0 }
            return n
        }
        func arg(_ i: Int) -> Int { i < fields.count && fields[i] != 0 ? fields[i] : 1 }
        switch final {
        case 0x41: row = max(0, row - arg(0)); wrapPending = false
        case 0x42: row = min(rows - 1, row + arg(0)); wrapPending = false
        case 0x43: column = min(columns - 1, column + arg(0)); wrapPending = false
        case 0x44: column = max(0, column - arg(0)); wrapPending = false
        case 0x47: column = min(columns - 1, max(0, arg(0) - 1)); wrapPending = false
        case 0x64: row = min(rows - 1, max(0, arg(0) - 1)); wrapPending = false
        case 0x45: row = min(rows - 1, row + arg(0)); column = 0; wrapPending = false
        case 0x46: row = max(0, row - arg(0)); column = 0; wrapPending = false
        case 0x48, 0x66: row = min(rows - 1, max(0, arg(0) - 1)); column = min(columns - 1, max(0, arg(1) - 1)); wrapPending = false
        case 0x4a:
            let mode = fields.first ?? 0
            if mode == 2 || mode == 3 { cells = Array(repeating: Array(repeating: " ", count: columns), count: rows) }
            else if mode == 0 { for r in row..<rows { let start = r == row ? column : 0; if start < columns { for c in start..<columns { clearCell(r, c) } } } }
            else if mode == 1 { for r in 0...row { let end = r == row ? column : columns - 1; for c in 0...min(end, columns - 1) { clearCell(r, c) } } }
        case 0x4b:
            let mode = fields.first ?? 0
            if mode == 2 { cells[row] = Array(repeating: " ", count: columns) }
            else if mode == 0 { for c in column..<columns { clearCell(row, c) } }
            else if mode == 1 { for c in 0...column { clearCell(row, c) } }
        case 0x73: savedRow = row; savedColumn = column
        case 0x75: row = savedRow; column = savedColumn; wrapPending = false
        case 0x6d: break // SGR does not affect displayed text
        default: cells = Array(repeating: Array(repeating: " ", count: columns), count: rows); row = 0; column = 0; wrapPending = false
        }
    }
}
