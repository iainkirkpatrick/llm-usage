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
    private static let hoverAccessibilityHelp = "Move the pointer over a day in the chart to inspect its exact local date and token count."

    private let summaries: [Summary]
    private let buckets: [PiDailyUsageBucket]
    private let peakTokens: Int
    private let viewSize: NSSize
    private let accessibilitySummary: String
    private var trackingArea: NSTrackingArea?
    private var hoveredBucketIndex: Int?

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
        self.setAccessibilityHelp(Self.hoverAccessibilityHelp)
        self.toolTip = self.accessibilitySummary
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        self.viewSize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = self.trackingArea {
            self.removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }

        guard let window = self.window else { return }

        // Menu windows are not consistently key windows across macOS versions.
        // activeAlways keeps inspection working while the menu is being tracked.
        window.acceptsMouseMovedEvents = true
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect,
        ]
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: options,
            owner: self,
            userInfo: nil)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard self.window != nil else {
            self.setHoveredBucket(nil)
            return
        }
        self.window?.acceptsMouseMovedEvents = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        self.updateHoveredBucket(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        self.updateHoveredBucket(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        self.setHoveredBucket(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let chartRect = self.chartRect()
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

        let plotRect = self.plotRect(in: chartRect)

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

        self.drawHoverHighlight(in: plotRect)
        self.drawGrid(in: plotRect)

        let values = self.buckets.map { max(0, $0.totalTokens) }
        self.drawBars(values: values, in: plotRect)
        self.drawHoverCallout(in: plotRect)

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

    private func chartRect() -> NSRect {
        NSRect(
            x: 0,
            y: 0,
            width: self.bounds.width,
            height: min(Self.chartHeight, self.bounds.height))
    }

    private func plotRect(in chartRect: NSRect) -> NSRect {
        NSRect(
            x: Self.horizontalInset,
            y: 23,
            width: max(1, chartRect.width - (Self.horizontalInset * 2)),
            height: max(1, chartRect.height - 50))
    }

    private func updateHoveredBucket(at location: NSPoint) {
        self.setHoveredBucket(self.bucketIndex(at: location))
    }

    private func bucketIndex(at location: NSPoint) -> Int? {
        guard !self.buckets.isEmpty else { return nil }

        let plotRect = self.plotRect(in: self.chartRect())
        guard plotRect.width > 0,
              plotRect.height > 0,
              location.x >= plotRect.minX,
              location.x <= plotRect.maxX,
              location.y >= plotRect.minY,
              location.y <= plotRect.maxY
        else {
            return nil
        }

        let slotWidth = plotRect.width / CGFloat(self.buckets.count)
        guard slotWidth.isFinite, slotWidth > 0 else { return nil }

        let position = (location.x - plotRect.minX) / slotWidth
        guard position.isFinite else { return nil }

        // Clamp the right edge so a point exactly on plotRect.maxX still selects today.
        let index = Int(position.rounded(.down))
        return min(max(index, 0), self.buckets.count - 1)
    }

    private func setHoveredBucket(_ index: Int?) {
        let normalizedIndex: Int?
        if let index, self.buckets.indices.contains(index) {
            normalizedIndex = index
        } else {
            normalizedIndex = nil
        }

        guard normalizedIndex != self.hoveredBucketIndex else { return }
        self.hoveredBucketIndex = normalizedIndex
        self.updateAccessibilityForHover()
        self.needsDisplay = true
    }

    private func updateAccessibilityForHover() {
        guard let index = self.hoveredBucketIndex,
              self.buckets.indices.contains(index)
        else {
            self.setAccessibilityValue(self.accessibilitySummary)
            self.setAccessibilityHelp(Self.hoverAccessibilityHelp)
            self.toolTip = self.accessibilitySummary
            return
        }

        let detail = Self.hoverDetail(for: self.buckets[index])
        let hoverText = "Hovered day: \(detail)."
        self.setAccessibilityValue("\(self.accessibilitySummary) \(hoverText)")
        self.setAccessibilityHelp("\(hoverText) \(Self.hoverAccessibilityHelp)")
        self.toolTip = "\(self.accessibilitySummary) \(hoverText)"
    }

    private func drawHoverHighlight(in plotRect: NSRect) {
        guard let index = self.hoveredBucketIndex,
              self.buckets.indices.contains(index)
        else {
            return
        }

        let slot = self.slotRect(for: index, count: self.buckets.count, in: plotRect)
        let inset = min(0.5, min(slot.width, slot.height) / 2)
        let highlightRect = slot.insetBy(dx: inset, dy: inset)
        guard highlightRect.width > 0, highlightRect.height > 0 else { return }

        let highlight = NSBezierPath(
            roundedRect: highlightRect,
            xRadius: min(2, highlightRect.width / 2),
            yRadius: min(2, highlightRect.height / 2))
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        highlight.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        highlight.lineWidth = 0.5
        highlight.stroke()
    }

    private func drawHoverCallout(in plotRect: NSRect) {
        guard let index = self.hoveredBucketIndex,
              self.buckets.indices.contains(index)
        else {
            return
        }

        let bucket = self.buckets[index]
        let dateText = Self.exactLocalDateLabel(bucket.day)
        let tokenText = "\(Self.exactTokenCountLabel(max(0, bucket.totalTokens))) tokens"
        let dateFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let tokenFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 5
        let dateLineHeight: CGFloat = 12
        let tokenLineHeight: CGFloat = 14
        let textWidth = max(
            self.measure(dateText, with: dateFont).width,
            self.measure(tokenText, with: tokenFont).width)
        let desiredWidth = ceil(textWidth + (horizontalPadding * 2))
        let desiredHeight = verticalPadding * 2 + dateLineHeight + tokenLineHeight

        // Keep the complete callout inside the plot. This also leaves room for its
        // shadow without letting it clip at either edge of the menu view.
        let horizontalEdgeInset = min(2, plotRect.width / 2)
        let verticalEdgeInset = min(2, plotRect.height / 2)
        let availableRect = plotRect.insetBy(
            dx: horizontalEdgeInset,
            dy: verticalEdgeInset)
        guard availableRect.width > 0, availableRect.height > 0 else { return }

        let calloutWidth = min(availableRect.width, max(96, desiredWidth))
        let calloutHeight = min(availableRect.height, desiredHeight)
        let slot = self.slotRect(for: index, count: self.buckets.count, in: plotRect)
        let barTop = self.barRect(
            for: max(0, bucket.totalTokens),
            at: index,
            count: self.buckets.count,
            in: plotRect)?.maxY ?? plotRect.minY
        let gap: CGFloat = 4
        let preferredY = barTop + gap
        let fallbackY = barTop - calloutHeight - gap
        let y = preferredY + calloutHeight <= availableRect.maxY ? preferredY : fallbackY
        let requestedRect = NSRect(
            x: slot.midX - (calloutWidth / 2),
            y: y,
            width: calloutWidth,
            height: calloutHeight)
        let calloutRect = Self.clamped(requestedRect, to: availableRect)

        let path = NSBezierPath(
            roundedRect: calloutRect,
            xRadius: min(6, calloutRect.width / 2),
            yRadius: min(6, calloutRect.height / 2))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor.controlBackgroundColor.withAlphaComponent(0.98).setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let textRect = calloutRect.insetBy(dx: horizontalPadding, dy: verticalPadding)
        self.drawFittedText(
            dateText,
            in: NSRect(
                x: textRect.minX,
                y: textRect.maxY - dateLineHeight,
                width: textRect.width,
                height: dateLineHeight),
            fontSize: 9,
            minimumFontSize: 7,
            weight: .semibold,
            color: .secondaryLabelColor)
        self.drawFittedText(
            tokenText,
            in: NSRect(
                x: textRect.minX,
                y: textRect.minY,
                width: textRect.width,
                height: tokenLineHeight),
            fontSize: 10,
            minimumFontSize: 7,
            weight: .medium,
            color: .labelColor)
    }

    private func slotRect(for index: Int, count: Int, in plotRect: NSRect) -> NSRect {
        let slotWidth = plotRect.width / CGFloat(count)
        return NSRect(
            x: plotRect.minX + (CGFloat(index) * slotWidth),
            y: plotRect.minY,
            width: slotWidth,
            height: plotRect.height)
    }

    private func barRect(
        for value: Int,
        at index: Int,
        count: Int,
        in plotRect: NSRect
    ) -> NSRect? {
        let positiveValue = max(0, value)
        guard positiveValue > 0,
              self.peakTokens > 0,
              count > 0,
              index >= 0,
              index < count
        else {
            return nil
        }

        let maximum = Double(self.peakTokens)
        guard maximum.isFinite, maximum > 0 else { return nil }

        let slotWidth = plotRect.width / CGFloat(count)
        guard slotWidth.isFinite, slotWidth > 0 else { return nil }

        let gap = min(1.5, slotWidth * 0.25)
        let barWidth = max(0.75, slotWidth - gap)
        let fraction = min(1.0, max(0, Double(positiveValue) / maximum))
        guard fraction.isFinite else { return nil }

        let barHeight = max(1.5, plotRect.height * CGFloat(fraction))
        let slot = self.slotRect(for: index, count: count, in: plotRect)
        return NSRect(
            x: slot.minX + ((slot.width - barWidth) / 2),
            y: plotRect.minY,
            width: barWidth,
            height: min(plotRect.height, barHeight))
    }

    private static func clamped(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        let width = min(max(0, rect.width), max(0, bounds.width))
        let height = min(max(0, rect.height), max(0, bounds.height))
        return NSRect(
            x: min(max(rect.minX, bounds.minX), bounds.maxX - width),
            y: min(max(rect.minY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height)
    }

    private static func exactLocalDateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func exactTokenCountLabel(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func hoverDetail(for bucket: PiDailyUsageBucket) -> String {
        let date = self.exactLocalDateLabel(bucket.day)
        let tokens = self.exactTokenCountLabel(max(0, bucket.totalTokens))
        return "\(date): \(tokens) tokens"
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

    private func drawBars(values: [Int], in plotRect: NSRect) {
        guard !values.isEmpty, self.peakTokens > 0, plotRect.width > 0, plotRect.height > 0 else {
            return
        }

        let todayIndex = values.index(before: values.endIndex)
        for (index, value) in values.enumerated() {
            guard let barRect = self.barRect(
                for: value,
                at: index,
                count: values.count,
                in: plotRect)
            else {
                continue
            }

            let bar = NSBezierPath(
                roundedRect: barRect,
                xRadius: min(1, barRect.width / 2),
                yRadius: min(1, barRect.height / 2))

            // A slightly stronger final bar marks today without competing with the data.
            let color = index == todayIndex
                ? NSColor.controlAccentColor
                : NSColor.controlAccentColor.withAlphaComponent(0.58)
            color.setFill()
            bar.fill()
        }
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
