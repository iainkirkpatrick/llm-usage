import AppKit
import Foundation

@MainActor
final class PiUsageSummaryChartView: NSView {
    struct Summary {
        let title: String
        let detail: String
    }

    private static let minimumWidth: CGFloat = 400
    private static let maximumWidth: CGFloat = 460
    private static let horizontalInset: CGFloat = 14
    private static let columnGap: CGFloat = 18
    private static let summaryRowHeight: CGFloat = 29
    private static let cellHorizontalInset: CGFloat = 9
    private static let summaryHeight: CGFloat = 58
    private static let chartHeight: CGFloat = 106
    private static let sectionGap: CGFloat = 6
    private static let topInset: CGFloat = 10
    private static let viewHeight: CGFloat = 180

    private let summaries: [Summary]
    private let buckets: [PiDailyUsageBucket]
    private let peakTokens: Int
    private let viewSize: NSSize
    private let accessibilitySummary: String

    init(summaries: [Summary], buckets: [PiDailyUsageBucket]) {
        let viewSummaries = Array(summaries.prefix(4))
        let size = NSSize(
            width: Self.width(for: viewSummaries),
            height: Self.viewHeight)

        self.summaries = viewSummaries
        self.buckets = buckets
        self.peakTokens = buckets.map { max(0, $0.totalTokens) }.max() ?? 0
        self.viewSize = size
        self.accessibilitySummary = Self.makeAccessibilitySummary(
            summaries: viewSummaries,
            buckets: buckets)
        super.init(frame: NSRect(origin: .zero, size: size))

        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel("Pi usage summaries and 90-day token usage chart")
        self.setAccessibilityValue(self.accessibilitySummary)
        self.toolTip = self.accessibilitySummary
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        self.viewSize
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let chartRect = NSRect(
            x: 0,
            y: 0,
            width: self.bounds.width,
            height: min(Self.chartHeight, self.bounds.height))
        let summaryRect = NSRect(
            x: 0,
            y: chartRect.maxY + Self.sectionGap,
            width: self.bounds.width,
            height: max(0, min(Self.summaryHeight, self.bounds.maxY - chartRect.maxY - Self.sectionGap - Self.topInset)))

        self.drawSummaries(in: summaryRect)
        self.drawChart(in: chartRect)
    }

    private func drawSummaries(in rect: NSRect) {
        guard !self.summaries.isEmpty, rect.height > 0 else { return }

        let availableWidth = max(
            1,
            rect.width - (Self.horizontalInset * 2) - Self.columnGap)
        let columnWidth = availableWidth / 2
        let labelFontSize: CGFloat = 10
        let detailFontSize: CGFloat = 11.5

        for (index, summary) in self.summaries.enumerated() {
            let row = index / 2
            guard row < 2 else { break }
            let column = index % 2
            let x = Self.horizontalInset + CGFloat(column) * (columnWidth + Self.columnGap)
            let y = rect.maxY - CGFloat(row + 1) * Self.summaryRowHeight + 1
            let cellRect = NSRect(
                x: x,
                y: y,
                width: columnWidth,
                height: Self.summaryRowHeight - 2)

            let background = NSBezierPath(roundedRect: cellRect, xRadius: 5, yRadius: 5)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.11).setFill()
            background.fill()

            let textRect = cellRect.insetBy(dx: Self.cellHorizontalInset, dy: 2)
            let labelRect = NSRect(
                x: textRect.minX,
                y: textRect.maxY - 12,
                width: textRect.width,
                height: 12)
            let detailRect = NSRect(
                x: textRect.minX,
                y: textRect.minY,
                width: textRect.width,
                height: 15)

            self.drawFittedText(
                summary.title,
                in: labelRect,
                fontSize: labelFontSize,
                minimumFontSize: 9,
                weight: .semibold,
                color: .secondaryLabelColor)
            self.drawFittedText(
                summary.detail,
                in: detailRect,
                fontSize: detailFontSize,
                minimumFontSize: 9,
                weight: .medium,
                color: .labelColor)
        }
    }

    private func drawChart(in chartRect: NSRect) {
        guard chartRect.width > 0, chartRect.height > 0 else { return }

        let horizontalInset = Self.horizontalInset
        let plotRect = NSRect(
            x: horizontalInset,
            y: 23,
            width: max(1, chartRect.width - (horizontalInset * 2)),
            height: max(1, chartRect.height - 50))

        let headerGap: CGFloat = 8
        let headerWidth = max(1, (plotRect.width - headerGap) / 2)
        self.drawFittedText(
            "Token usage · 90d",
            in: NSRect(
                x: plotRect.minX,
                y: plotRect.maxY + 4,
                width: headerWidth,
                height: 15),
            fontSize: 11,
            minimumFontSize: 9,
            weight: .semibold,
            color: .labelColor)
        self.drawFittedText(
            "Peak \(Self.compactTokenLabel(self.peakTokens))/day",
            in: NSRect(
                x: plotRect.minX + headerWidth + headerGap,
                y: plotRect.maxY + 4,
                width: headerWidth,
                height: 15),
            fontSize: 10,
            minimumFontSize: 8,
            color: .secondaryLabelColor,
            alignment: .right)

        let plotBackground = NSBezierPath(roundedRect: plotRect, xRadius: 5, yRadius: 5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
        plotBackground.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        plotBackground.lineWidth = 0.5
        plotBackground.stroke()

        self.drawGrid(in: plotRect)

        let values = self.buckets.map { Double(max(0, $0.totalTokens)) }
        let points = self.points(for: values, in: plotRect)
        if self.peakTokens > 0, !points.isEmpty {
            self.drawAreaAndLine(points: points, in: plotRect)
            self.drawPeakMarkers(points: points, values: values)
        } else {
            self.drawBaseline(in: plotRect)
        }

        let secondaryColor = NSColor.secondaryLabelColor
        let firstBucketLabel = self.buckets.first?.day.formatted(date: .abbreviated, time: .omitted) ?? "89d ago"
        self.drawFittedText(
            firstBucketLabel,
            in: NSRect(x: plotRect.minX, y: 2, width: plotRect.width / 3, height: 14),
            fontSize: 10,
            minimumFontSize: 8,
            color: secondaryColor)
        self.drawFittedText(
            "→",
            in: NSRect(x: plotRect.midX - 20, y: 2, width: 40, height: 14),
            fontSize: 10,
            minimumFontSize: 8,
            color: secondaryColor,
            alignment: .center)
        self.drawFittedText(
            "Today",
            in: NSRect(x: plotRect.maxX - (plotRect.width / 3), y: 2, width: plotRect.width / 3, height: 14),
            fontSize: 10,
            minimumFontSize: 8,
            color: secondaryColor,
            alignment: .right)
    }

    private func drawGrid(in plotRect: NSRect) {
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.28)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setStrokeColor(gridColor.cgColor)
            context.setLineWidth(0.5)
            context.setLineDash(phase: 0, lengths: [2, 3])
            context.move(to: CGPoint(x: plotRect.minX, y: plotRect.midY))
            context.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.midY))
            context.strokePath()
            context.restoreGState()
        }

        self.drawBaseline(in: plotRect)
    }

    private func drawBaseline(in plotRect: NSRect) {
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: plotRect.minX, y: plotRect.minY))
        baseline.line(to: NSPoint(x: plotRect.maxX, y: plotRect.minY))
        baseline.lineWidth = 0.75
        NSColor.secondaryLabelColor.withAlphaComponent(0.42).setStroke()
        baseline.stroke()
    }

    private func points(for values: [Double], in plotRect: NSRect) -> [NSPoint] {
        guard !values.isEmpty else { return [] }

        let finitePeak = Double(self.peakTokens)
        let denominator = max(1, values.count - 1)
        return values.enumerated().map { index, value in
            let fraction: CGFloat
            if finitePeak.isFinite, finitePeak > 0, value.isFinite {
                fraction = CGFloat(min(1, max(0, value / finitePeak)))
            } else {
                fraction = 0
            }
            return NSPoint(
                x: plotRect.minX + (plotRect.width * CGFloat(index) / CGFloat(denominator)),
                y: plotRect.minY + (plotRect.height * fraction))
        }
    }

    private func drawAreaAndLine(points: [NSPoint], in plotRect: NSRect) {
        guard let first = points.first, let last = points.last else { return }

        let area = NSBezierPath()
        area.move(to: NSPoint(x: first.x, y: plotRect.minY))
        area.line(to: first)
        for point in points.dropFirst() {
            area.line(to: point)
        }
        area.line(to: NSPoint(x: last.x, y: plotRect.minY))
        area.close()
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        area.fill()

        let line = NSBezierPath()
        line.move(to: first)
        for point in points.dropFirst() {
            line.line(to: point)
        }
        line.lineWidth = 1.6
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        NSColor.controlAccentColor.setStroke()
        line.stroke()
    }

    private func drawPeakMarkers(points: [NSPoint], values: [Double]) {
        guard let peak = values.max(), peak > 0, peak.isFinite,
              let index = values.firstIndex(of: peak), index < points.count
        else { return }

        let point = points[index]
        let marker = NSBezierPath(ovalIn: NSRect(x: point.x - 2.25, y: point.y - 2.25, width: 4.5, height: 4.5))
        NSColor.controlAccentColor.setFill()
        marker.fill()
    }

    private func drawFittedText(
        _ text: String,
        in rect: NSRect,
        fontSize: CGFloat,
        minimumFontSize: CGFloat = 8,
        weight: NSFont.Weight = .regular,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }

        var size = fontSize
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        while size >= minimumFontSize {
            font = NSFont.systemFont(ofSize: size, weight: weight)
            if self.measure(text, with: font).width <= rect.width {
                break
            }
            size -= 0.5
        }

        let renderedText = Self.textFitting(text, width: rect.width, font: font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]
        let renderedSize = (renderedText as NSString).size(withAttributes: attributes)
        let x: CGFloat
        switch alignment {
        case .right:
            x = rect.maxX - renderedSize.width
        case .center:
            x = rect.midX - (renderedSize.width / 2)
        default:
            x = rect.minX
        }
        let y = rect.midY - (renderedSize.height / 2)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        (renderedText as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func measure(_ text: String, with font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private static func textFitting(_ text: String, width: CGFloat, font: NSFont) -> String {
        guard width > 0 else { return "" }
        guard (text as NSString).size(withAttributes: [.font: font]).width > width else {
            return text
        }

        var prefix = text
        while !prefix.isEmpty {
            prefix.removeLast()
            let candidate = prefix + "…"
            if (candidate as NSString).size(withAttributes: [.font: font]).width <= width {
                return candidate
            }
        }
        return "…"
    }

    private static func width(for summaries: [Summary]) -> CGFloat {
        let detailFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let widestDetail = summaries.map {
            ($0.detail as NSString).size(withAttributes: [.font: detailFont]).width
        }.max() ?? 0
        let measuredWidth = ceil(
            (widestDetail * 2) +
                Self.columnGap +
                (Self.horizontalInset * 2) +
                (Self.cellHorizontalInset * 4))
        return min(Self.maximumWidth, max(Self.minimumWidth, measuredWidth))
    }

    private static func makeAccessibilitySummary(
        summaries: [Summary],
        buckets: [PiDailyUsageBucket]
    ) -> String {
        let summaryText = summaries.map { "\($0.title): \($0.detail)" }.joined(separator: ". ")
        let graphText = self.makeGraphAccessibilitySummary(buckets: buckets)
        if summaryText.isEmpty { return graphText }
        return "\(summaryText). \(graphText)"
    }

    private static func makeGraphAccessibilitySummary(buckets: [PiDailyUsageBucket]) -> String {
        let values = buckets.map { max(0, $0.totalTokens) }
        let peak = values.max() ?? 0
        let activeDays = values.filter { $0 > 0 }.count
        let today = values.last ?? 0

        guard !buckets.isEmpty else {
            return "Pi token usage chart for the last 90 days is unavailable."
        }
        let firstBucketLabel = buckets[0].day.formatted(date: .abbreviated, time: .omitted)
        guard peak > 0 else {
            return "No Pi token usage recorded in 90 local calendar days from \(firstBucketLabel) through today. All 90 daily buckets are zero."
        }

        return "Pi token usage chart for 90 local calendar days from \(firstBucketLabel) through today: \(activeDays) days with usage; peak \(Self.compactTokenLabel(peak)) tokens in one day; today \(Self.compactTokenLabel(today)) tokens."
    }

    private static func compactTokenLabel(_ value: Int) -> String {
        guard value > 0 else { return "0" }

        let threshold: Double
        let suffix: String
        switch value {
        case 1_000_000_000...:
            threshold = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            threshold = 1_000_000
            suffix = "M"
        case 1_000...:
            threshold = 1_000
            suffix = "k"
        default:
            return String(value)
        }

        let scaled = Double(value) / threshold
        let text = scaled >= 10 || scaled.rounded() == scaled
            ? String(format: "%.0f", scaled)
            : String(format: "%.1f", scaled)
        return "\(text)\(suffix)"
    }
}
