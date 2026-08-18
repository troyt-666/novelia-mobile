import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var externalLinksChannel: FlutterMethodChannel?
  private var accountSessionChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let registrar = flutterViewController.registrar(forPlugin: "ExternalLinkLauncher")
    let channel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/external_links",
      binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let rawUrl = call.arguments as? String,
        let url = URL(string: rawUrl),
        url.scheme == "https" || url.scheme == "http"
      else {
        result(
          FlutterError(
            code: "INVALID_URL",
            message: "Only HTTP(S) links are allowed.",
            details: nil
          )
        )
        return
      }
      result(NSWorkspace.shared.open(url))
    }
    externalLinksChannel = channel

    let accountChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/account_session",
      binaryMessenger: registrar.messenger)
    accountChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "read":
        result(Self.readAccountSession())
      case "write":
        guard let value = call.arguments as? String else {
          result(FlutterError(
            code: "INVALID_VALUE",
            message: "Session must be text.",
            details: nil))
          return
        }
        Self.writeAccountSession(value)
        result(nil)
      case "clear":
        Self.clearAccountSession()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    accountSessionChannel = accountChannel

    super.awakeFromNib()
  }

  private static let accountSessionKey =
    "io.github.troyt666.jfzreader.account.session-v1"

  private static func readAccountSession() -> String? {
    return UserDefaults.standard.string(forKey: accountSessionKey)
  }

  private static func writeAccountSession(_ value: String) {
    UserDefaults.standard.set(value, forKey: accountSessionKey)
  }

  private static func clearAccountSession() {
    UserDefaults.standard.removeObject(forKey: accountSessionKey)
  }
}
