import Cocoa

// MARK: - Entry point

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--write-icon" {
    var artwork: CGImage?
    if arguments.count >= 4 {
        artwork = artworkTrimmedToContent(atPath: arguments[3])
        guard let artwork else {
            print("could not read the icon artwork at \(arguments[3])")
            exit(1)
        }
        print("  artwork trimmed to \(artwork.width)x\(artwork.height)")
    }
    for pixels in [16, 32, 64, 128, 256, 512, 1024] {
        guard let png = drawIcon(pixels: pixels, artwork: artwork) else { exit(1) }
        try! png.write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("icon_\(pixels).png"))
    }
    exit(0)
}

if arguments.count == 2, arguments[1] == "--self-check" {
    _ = NSApplication.shared
    SelfCheck().run()
}

let app = NSApplication.shared

if arguments.count == 3, arguments[1] == "--render-page" {
    app.setActivationPolicy(.accessory)
    PageRender(directory: arguments[2]).run()
}

if arguments.count == 2, arguments[1] == "--find-check" {
    app.setActivationPolicy(.accessory)
    FindCheck().run()
}

if arguments.count == 2, arguments[1] == "--file-check" {
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.reportFiles()
}

if arguments.count == 2, arguments[1] == "--tabs-check" {
    // Regular, not accessory: undo registration needs a window that can focus.
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    delegate.reportTabs()
}

if arguments.count >= 2, arguments[1] == "--layout-check" {
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.reportLayout(renderingInto: arguments.count >= 3 ? arguments[2] : nil)
}

app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
