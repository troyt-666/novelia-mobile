import AppKit
import WebKit

// Runs the generated document in the same engine used by the macOS reader.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.userContentController.addUserScript(WKUserScript(source: "window.testErrors=[];window.addEventListener('error',e=>testErrors.push(e.message));window.testMessages=[];window.testUnsafe=false;window.ReaderBridge={postMessage:s=>testMessages.push(JSON.parse(s))};window.alert=window.attack=()=>{testUnsafe=true};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 430, height: 720), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView
window.orderFrontRegardless()
let arguments = CommandLine.arguments
var activePath = arguments[2]
let script = try String(contentsOfFile: arguments[1], encoding: .utf8)
Task { @MainActor in
    do {
        for path in arguments.dropFirst(2) {
            activePath = path
            webView.loadHTMLString(try String(contentsOfFile: path, encoding: .utf8), baseURL: nil)
            var ready = false
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if !webView.isLoading, let value = try? await webView.evaluateJavaScript("typeof readerProgress === 'function' && JSON.parse(readerProgress()).ready"), value as? Bool == true {
                    ready = true
                    break
                }
            }
            if !ready {
                let diagnostic = try? await webView.evaluateJavaScript("JSON.stringify({errors:testErrors, scripts:document.scripts.length, progress:typeof readerProgress, state:document.readyState, images:Array.from(document.images).map(i=>i.complete),visibility:document.visibilityState,fontStatus:document.fonts.status})")
                print(diagnostic ?? "no diagnostics")
            }
            guard ready else { throw NSError(domain: "Reader layout did not become ready", code: 1) }
            let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            print(result ?? "passed")
        }
        exit(0)
    } catch {
        fputs("WKWebView contract failed: \(error)\n", stderr)
        if let snapshot = try? await webView.takeSnapshot(configuration: nil), let data = snapshot.tiffRepresentation {
            try? data.write(to: URL(fileURLWithPath: activePath + ".failure.tiff"))
        }
        exit(1)
    }
}
app.run()
