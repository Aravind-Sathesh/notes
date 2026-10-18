import Cocoa
import ImageIO

// MARK: - Icon rendering
//
// macOS icons are not full bleed: on a 1024pt canvas the artwork body is
// 824x824 centred. Supplied artwork that already carries its own rounded
// corners is placed on that grid untouched — masking it again would round the
// corners twice. The built-in mark, having no shape of its own, gets one.

private let iconBodyRatio: CGFloat = 824.0 / 1024.0

// Measured off the system's own icons — see the shadow note in drawIcon.
private let iconShadowBlur: CGFloat = 0.024
private let iconShadowOffset: CGFloat = 0.008
private let iconShadowOpacity: CGFloat = 0.35

/// Apple's corner is a superellipse rather than an arc: the curvature eases in
/// instead of meeting the straight edge abruptly. Exponent 5 matches the
/// system's own icons to within half a percent of canvas width, measured.
private func squirclePath(in rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let steps = 720

    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = rect.midX + halfWidth * copysign(pow(abs(cosine), 2 / exponent), cosine)
        let y = rect.midY + halfHeight * copysign(pow(abs(sine), 2 / exponent), sine)
        if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Trims the transparent surround, so the artwork's own edges define the icon
/// body rather than whatever padding the export happened to include.
func artworkTrimmedToContent(atPath path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

    let width = image.width, height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return image }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return image }

    return image.cropping(to: CGRect(
        x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
    )) ?? image
}

func drawIcon(pixels: Int, artwork: CGImage?) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let bodySide = size * iconBodyRatio
    let body = NSRect(x: (size - bodySide) / 2, y: (size - bodySide) / 2,
                      width: bodySide, height: bodySide)

    if let artwork {
        // Fills the body box. The trimmed artwork is square to within a pixel —
        // the difference is corner antialiasing, not intent — so this puts it
        // on the grid in both directions rather than leaving it short in one.
        let target = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height)

        // Every system icon bakes a drop shadow; the Dock does not add one.
        // Without it the icon reads as flatter and smaller than its neighbours.
        // These numbers come from measuring Apple's own icons: their alpha
        // reaches 0.8% of the canvas above the body and 2.4% below it, which is
        // a blur of 1.6% offset 0.8% downwards.
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.setShadow(
                offset: CGSize(width: 0, height: -size * iconShadowOffset),
                blur: size * iconShadowBlur,
                color: NSColor.black.withAlphaComponent(iconShadowOpacity).cgColor
            )
            cg.draw(artwork, in: target)
            cg.restoreGState()
        }
    } else {
        Theme.dark.background.setFill()
        squirclePath(in: body).fill()

        let glyph = ">_" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size * 0.30, weight: .bold),
            .foregroundColor: Theme.dark.foreground,
        ]
        let measured = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2 + size * 0.03),
            withAttributes: attributes
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
