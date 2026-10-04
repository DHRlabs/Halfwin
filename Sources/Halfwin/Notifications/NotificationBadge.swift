import AppKit
import CoreText

enum NotificationBadgeRenderer {
    private static let badgeHeight: CGFloat = 15
    private static let dotDiameter: CGFloat = 5.5
    private static let horizontalPadding: CGFloat = 5
    private static let fontSize: CGFloat = 10

    static func appendBadge(to title: NSMutableAttributedString, count: Int, showsCount: Bool) {
        guard count > 0, let image = image(count: count, showsCount: showsCount) else { return }

        title.append(NSAttributedString(string: " "))
        let attachment = NSTextAttachment()
        attachment.image = image
        let menuFont = NSFont.menuFont(ofSize: 0)
        let baselineOffset = (menuFont.ascender + menuFont.descender - image.size.height) / 2
        attachment.bounds = NSRect(x: 0, y: baselineOffset, width: image.size.width, height: image.size.height)
        title.append(NSAttributedString(attachment: attachment))
        title.append(NSAttributedString(string: " "))
    }

    static func image(count: Int, showsCount: Bool) -> NSImage? {
        guard count > 0 else { return nil }
        guard showsCount else {
            let size = NSSize(width: dotDiameter, height: dotDiameter)
            return NSImage(size: size, flipped: false) { rect in
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
        }

        let label = count > 99 ? "99+" : String(count)
        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: fontSize, weight: .bold).fontName as CFString,
                                        fontSize, nil)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let width = label.count == 1
            ? badgeHeight
            : max(badgeHeight, ceil(textWidth + horizontalPadding * 2))
        let size = NSSize(width: width, height: badgeHeight)

        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }

            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.textMatrix = .identity
            context.textPosition = CGPoint(
                x: (rect.width - textWidth) / 2,
                y: (rect.height - (ascent + descent)) / 2 + descent + 0.2
            )
            CTLineDraw(line, context)
            return true
        }
    }
}
