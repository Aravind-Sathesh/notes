import Cocoa

// MARK: - Theme
//
// Mirrors the page's CSS variables so the titlebar and tab bar are the same
// surface as the note, in either theme.

struct Theme {
    var background: NSColor
    var foreground: NSColor
    var dim: NSColor
    var border: NSColor

    static let dark = Theme(
        background: color(fromCSSHex: "#101010")!,
        foreground: color(fromCSSHex: "#ededed")!,
        dim: color(fromCSSHex: "#6b6b6b")!,
        border: color(fromCSSHex: "#262626")!
    )

    static let light = Theme(
        background: color(fromCSSHex: "#f5f5f5")!,
        foreground: color(fromCSSHex: "#141414")!,
        dim: color(fromCSSHex: "#8a8a8a")!,
        border: color(fromCSSHex: "#dcdcdc")!
    )

    var isDark: Bool {
        let srgb = background.usingColorSpace(.sRGB) ?? background
        return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent < 0.5
    }

    /// Tint for the selected tab: lifted away from the page in dark mode,
    /// pressed into it in light mode, so it reads as raised either way.
    var activeTabFill: NSColor {
        let target: NSColor = isDark ? .white : .black
        return background.blended(withFraction: isDark ? 0.10 : 0.06, of: target) ?? background
    }

    init(background: NSColor, foreground: NSColor, dim: NSColor, border: NSColor) {
        self.background = background
        self.foreground = foreground
        self.dim = dim
        self.border = border
    }

    init?(cssVariables: [String: String]) {
        guard let bg = cssVariables["bg"].flatMap(color(fromCSSHex:)),
              let fg = cssVariables["fg"].flatMap(color(fromCSSHex:)),
              let dim = cssVariables["dim"].flatMap(color(fromCSSHex:)),
              let border = cssVariables["border"].flatMap(color(fromCSSHex:)) else { return nil }
        self.init(background: bg, foreground: fg, dim: dim, border: border)
    }
}

func color(fromCSSHex hex: String) -> NSColor? {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    guard digits.hasPrefix("#") else { return nil }
    digits.removeFirst()
    if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1
    )
}
