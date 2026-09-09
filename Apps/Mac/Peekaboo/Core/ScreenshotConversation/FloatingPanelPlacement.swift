import CoreGraphics

enum FloatingPanelPlacement {
    private nonisolated static let gap: CGFloat = 12
    private nonisolated static let margin: CGFloat = 16

    nonisolated static func origin(
        selectionRect: CGRect,
        visibleFrame: CGRect,
        panelSize: CGSize) -> CGPoint
    {
        let rightX = selectionRect.maxX + Self.gap
        let leftX = selectionRect.minX - Self.gap - panelSize.width
        let rightSpace = visibleFrame.maxX - Self.margin - rightX
        let leftSpace = leftX - (visibleFrame.minX + Self.margin)

        let proposedX: CGFloat
        if rightX + panelSize.width <= visibleFrame.maxX - Self.margin {
            proposedX = rightX
        } else if leftX >= visibleFrame.minX + Self.margin {
            proposedX = leftX
        } else if rightSpace >= leftSpace {
            proposedX = rightX
        } else {
            proposedX = leftX
        }

        let proposedY = selectionRect.maxY - panelSize.height
        return CGPoint(
            x: Self.clampedX(
                proposedX,
                visibleFrame: visibleFrame,
                panelWidth: panelSize.width),
            y: Self.clampedY(
                proposedY,
                visibleFrame: visibleFrame,
                panelHeight: panelSize.height))
    }

    nonisolated static func clampedX(
        _ proposedX: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat) -> CGFloat
    {
        Self.clamp(
            proposedX,
            lowerBound: visibleFrame.minX + Self.margin,
            upperBound: visibleFrame.maxX - Self.margin - panelWidth)
    }

    private nonisolated static func clampedY(
        _ proposedY: CGFloat,
        visibleFrame: CGRect,
        panelHeight: CGFloat) -> CGFloat
    {
        Self.clamp(
            proposedY,
            lowerBound: visibleFrame.minY + Self.margin,
            upperBound: visibleFrame.maxY - Self.margin - panelHeight)
    }

    private nonisolated static func clamp(
        _ value: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat) -> CGFloat
    {
        guard upperBound >= lowerBound else {
            return lowerBound
        }
        return min(max(value, lowerBound), upperBound)
    }
}
