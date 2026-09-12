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
        let rightSpace = visibleFrame.maxX - Self.margin - selectionRect.maxX - Self.gap
        let leftSpace = selectionRect.minX - Self.gap - (visibleFrame.minX + Self.margin)

        let proposedX: CGFloat
        if rightX + panelSize.width <= visibleFrame.maxX - Self.margin {
            proposedX = rightX
        } else if leftX >= visibleFrame.minX + Self.margin {
            proposedX = leftX
        } else if rightSpace > leftSpace {
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

enum FloatingPanelGeometry {
    nonisolated static let minimumSize = CGSize(width: 360, height: 260)
    nonisolated static let defaultSize = CGSize(width: 460, height: 600)
    nonisolated static let margin: CGFloat = 16

    nonisolated static func normalizedFrame(
        _ frame: CGRect,
        screens: [CGRect],
        fallbackScreen: CGRect?,
        margin: CGFloat = Self.margin) -> CGRect?
    {
        let validScreens = screens.filter(Self.isValidScreen)
        guard !validScreens.isEmpty else { return nil }

        let targetScreen = Self.targetScreen(
            for: frame,
            screens: validScreens,
            fallbackScreen: fallbackScreen) ?? validScreens[0]
        let horizontalMargin = min(max(0, margin), targetScreen.width / 2)
        let verticalMargin = min(max(0, margin), targetScreen.height / 2)
        let usableFrame = targetScreen.insetBy(dx: horizontalMargin, dy: verticalMargin)
        let usableSize = CGSize(width: max(0, usableFrame.width), height: max(0, usableFrame.height))
        let effectiveMinimum = CGSize(
            width: min(Self.minimumSize.width, usableSize.width),
            height: min(Self.minimumSize.height, usableSize.height))
        let proposedSize = Self.isValidFrame(frame) ? frame.size : Self.defaultSize
        let size = CGSize(
            width: Self.clamp(proposedSize.width, lowerBound: effectiveMinimum.width, upperBound: usableSize.width),
            height: Self.clamp(proposedSize.height, lowerBound: effectiveMinimum.height, upperBound: usableSize.height))

        return CGRect(
            x: Self.clamp(
                frame.minX.isFinite ? frame.minX : usableFrame.minX,
                lowerBound: usableFrame.minX,
                upperBound: usableFrame.maxX - size.width),
            y: Self.clamp(
                frame.minY.isFinite ? frame.minY : usableFrame.minY,
                lowerBound: usableFrame.minY,
                upperBound: usableFrame.maxY - size.height),
            width: size.width,
            height: size.height)
    }

    nonisolated static func maximumSize(for screen: CGRect, margin: CGFloat = Self.margin) -> CGSize {
        guard Self.isValidScreen(screen) else { return .zero }
        return CGSize(
            width: max(0, screen.width - min(max(0, margin), screen.width / 2) * 2),
            height: max(0, screen.height - min(max(0, margin), screen.height / 2) * 2))
    }

    nonisolated static func targetScreen(
        for frame: CGRect,
        screens: [CGRect],
        fallbackScreen: CGRect?) -> CGRect?
    {
        let validScreens = screens.filter(Self.isValidScreen)
        guard !validScreens.isEmpty else { return nil }
        let fallback = fallbackScreen.flatMap { candidate in
            validScreens.first(where: { $0 == candidate })
        }
        return Self.screenWithGreatestIntersection(frame, in: validScreens) ?? fallback ?? validScreens[0]
    }

    private nonisolated static func screenWithGreatestIntersection(
        _ frame: CGRect,
        in screens: [CGRect]) -> CGRect?
    {
        var bestScreen: CGRect?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = frame.intersection(screen)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        return bestScreen
    }

    private nonisolated static func isValidScreen(_ screen: CGRect) -> Bool {
        screen.minX.isFinite && screen.minY.isFinite &&
            screen.width.isFinite && screen.height.isFinite &&
            screen.width > 0 && screen.height > 0
    }

    nonisolated static func isValidFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0
    }

    private nonisolated static func clamp(
        _ value: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat) -> CGFloat
    {
        guard upperBound >= lowerBound else { return lowerBound }
        return min(max(value, lowerBound), upperBound)
    }
}
