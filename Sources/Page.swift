import Cocoa
import WebKit
import UniformTypeIdentifiers

// MARK: - Window content
//
// Frames are set by hand rather than with autoresizing masks, because the find
// bar appears and disappears between the tab strip and the note.

final class RootView: NSView {
    var onResize: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        onResize?()
    }
}

// MARK: - Bridge into the page
//
// notes.html stays untouched so it still works on its own in Safari and on
// iOS. Everything native hooks onto its existing elements and events.

// Read on first use, so --write-icon, which never builds a web view, does
// not need the resources.
private enum Bridge {
    static let source = resource("bridge", "js")

    /// bridge.css, as a script that adds it to the page. Injected just before
    /// bridge.js rather than linked, so nothing it styles appears unstyled
    /// while a stylesheet loads.
    static let style: String = {
        guard let data = try? JSONEncoder().encode(resource("bridge", "css")),
              let literal = String(data: data, encoding: .utf8) else { fatalError("bridge.css is not encodable") }
        return "(function () { var s = document.createElement('style'); s.textContent = \(literal);"
            + " document.head.appendChild(s); })();"
    }()

    private static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Saving, find, theme sync and the outline all ride on these files;
            // a bundle without them is broken in a way that must not fail quietly.
            fatalError("\(name).\(ext) missing from the app bundle")
        }
        return text
    }
}

/// Builds a web view for one note. The app and its checks share this so they
/// exercise the same loading and persistence path.
func makeWebView(
    handlingMessagesFor handler: WKScriptMessageHandler,
    isolated: Bool = false
) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(LocalContentHandler(), forURLScheme: "notes")
    // The page keeps its own localStorage copy, shared by every run of this
    // bundle. The checks must not write into the copy the real app reads.
    configuration.websiteDataStore = (isolated || runningACheck) ? .nonPersistent() : .default()
    configuration.userContentController.add(handler, name: "save")
    configuration.userContentController.add(handler, name: "theme")
    // Scripts at the same injection time run in the order they are added.
    for source in [Bridge.style, Bridge.source] {
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")  // no white flash before first paint
    return webView
}

// MARK: - Serving the page over a real origin
//
// Serving over a custom scheme rather than file:// gives the page a real
// security origin, so its own localStorage cache works at all.

final class LocalContentHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let root = contentDirectory().standardizedFileURL
        let requested = task.request.url?.path ?? "/"
        let file = root.appendingPathComponent(requested).standardizedFileURL

        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        // UTType has no mapping for web font types, and a font served as
        // application/octet-stream is refused.
        let webTypes = [
            "html": "text/html; charset=utf-8",
            "js": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "woff2": "font/woff2",
            "woff": "font/woff",
        ]
        let mime = webTypes[file.pathExtension.lowercased()]
            ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]
        )!

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
