import AppKit
import Foundation

@MainActor
enum StatusIconText {
    private static let codexImage = Self.loadTemplateImage(named: "ProviderIcon-codex")
    private static let openCodeImage = Self.loadTemplateImage(named: "ProviderIcon-opencode")

    private static let logoSize = NSSize(width: 16, height: 16)
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)

    static func makeStackedImage(
        codexSession: Int?,
        codexSessionResetAt: Date?,
        codexWeekly: Int?,
        codexWeeklyResetAt: Date?,
        openCodeSession: Int?,
        openCodeSessionResetAt: Date?,
        openCodeWeekly: Int?,
        openCodeWeeklyResetAt: Date?
    ) -> NSImage?
    {
        var segments: [NSImage] = []

        if codexSession != nil || codexWeekly != nil {
            if let segment = self.makeSegment(
                logo: self.codexImage,
                top: self.labeledPercent(prefix: "S", value: codexSession, resetAt: codexSessionResetAt),
                bottom: self.labeledPercent(prefix: "W", value: codexWeekly, resetAt: codexWeeklyResetAt)
            ) {
                segments.append(segment)
            }
        }

        if openCodeSession != nil || openCodeWeekly != nil {
            if let segment = self.makeSegment(
                logo: self.openCodeImage,
                top: self.labeledPercent(prefix: "S", value: openCodeSession, resetAt: openCodeSessionResetAt),
                bottom: self.labeledPercent(prefix: "W", value: openCodeWeekly, resetAt: openCodeWeeklyResetAt)
            ) {
                segments.append(segment)
            }
        }

        guard !segments.isEmpty else { return nil }

        let spacing: CGFloat = 4
        let totalWidth = segments.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, segments.count - 1))
        let totalHeight = segments.map(\.size.height).max() ?? 16

        let canvas = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        canvas.lockFocus()

        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let y = (totalHeight - segment.size.height) / 2
            segment.draw(in: NSRect(x: x, y: y, width: segment.size.width, height: segment.size.height))
            x += segment.size.width
            if index < segments.count - 1 {
                x += spacing
            }
        }

        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    private static func makeSegment(logo: NSImage?, top: String, bottom: String) -> NSImage? {
        guard let logo else { return nil }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: self.rowFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]

        let topWidth = (top as NSString).size(withAttributes: textAttributes).width
        let bottomWidth = (bottom as NSString).size(withAttributes: textAttributes).width
        let textWidth = ceil(max(topWidth, bottomWidth))

        let stacked = "\(top)\n\(bottom)" as NSString
        let stackedSize = stacked.boundingRect(
            with: NSSize(width: max(1, textWidth), height: 100),
            options: [.usesLineFragmentOrigin],
            attributes: textAttributes
        ).size

        let height: CGFloat = 18
        let width: CGFloat = 1 + self.logoSize.width + 2 + textWidth + 1

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let logoRect = NSRect(x: 1, y: (height - self.logoSize.height) / 2, width: self.logoSize.width, height: self.logoSize.height)
        if let tinted = self.tintedLogo(logo, size: self.logoSize, color: .black) {
            tinted.draw(in: logoRect)
        }

        let textX = logoRect.maxX + 2
        let textY = floor((height - ceil(stackedSize.height)) / 2)
        stacked.draw(
            in: NSRect(x: textX, y: textY, width: textWidth, height: ceil(stackedSize.height)),
            withAttributes: textAttributes
        )

        image.unlockFocus()
        return image
    }

    private static func labeledPercent(prefix: String, value: Int?, resetAt: Date?) -> String {
        let amount = value.map { "\($0)%" } ?? "—"
        let reset = self.shortReset(resetAt)
        return "\(prefix) \(amount) \(reset)"
    }

    private static func shortReset(_ date: Date?) -> String {
        guard let date else { return "?" }
        let interval = Int(date.timeIntervalSinceNow)
        if interval <= 0 { return "now" }

        let days = interval / 86_400
        let hours = (interval % 86_400) / 3_600
        let minutes = (interval % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    private static func tintedLogo(_ image: NSImage, size: NSSize, color: NSColor) -> NSImage? {
        let base = image.copy() as? NSImage ?? image
        base.size = size

        let tinted = NSImage(size: size)
        tinted.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        color.setFill()
        rect.fill()
        base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)

        tinted.unlockFocus()
        return tinted
    }

    private static func loadTemplateImage(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data)
        else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}
