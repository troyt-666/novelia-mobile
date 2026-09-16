import Cocoa
import FlutterMacOS
import Sparkle

class MainFlutterWindow: NSWindow {
  private var externalLinksChannel: FlutterMethodChannel?
  private var appVersionChannel: FlutterMethodChannel?
  private var accountSessionChannel: FlutterMethodChannel?
  private var appUpdateInstallerChannel: FlutterMethodChannel?
  private var backupFilesChannel: FlutterMethodChannel?
  private var backupPickerOpen = false
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let registrar = flutterViewController.registrar(forPlugin: "ExternalLinkLauncher")
    let backupChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/backup_files", binaryMessenger: registrar.messenger)
    backupChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard call.method == "pickBackup" || call.method == "saveBackup" else {
        result(FlutterMethodNotImplemented); return
      }
      guard !self.backupPickerOpen else {
        result(FlutterError(code: "BUSY", message: "A document picker is already open.", details: nil)); return
      }
      self.backupPickerOpen = true
      if call.method == "saveBackup", let path = call.arguments as? String {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let destination = panel.url else {
            self.backupPickerOpen = false; result(false); return
          }
          self.transferBackup(from: URL(fileURLWithPath: path), to: destination, importing: false, result: result)
        }
      } else if call.method == "pickBackup" {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Custom backup extensions may have no registered UTI yet. Validate
        // the selected file in Dart instead of filtering it out here.
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let source = panel.url else {
            self.backupPickerOpen = false; result(nil); return
          }
          let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("jfz-backup-import-\(UUID().uuidString).jfzbackup")
          self.transferBackup(from: source, to: destination, importing: true, result: result)
        }
      } else {
        self.backupPickerOpen = false
        result(FlutterError(code: "INVALID_PATH", message: "Backup path is missing.", details: nil))
      }
    }
    backupFilesChannel = backupChannel
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

    let versionChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/app_version",
      binaryMessenger: registrar.messenger)
    versionChannel.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let info = Bundle.main.infoDictionary
      result([
        "name": info?["CFBundleShortVersionString"] as? String ?? "",
        "buildNumber": info?["CFBundleVersion"] as? String ?? "",
      ])
    }
    appVersionChannel = versionChannel

    let updateChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/app_update_installer",
      binaryMessenger: registrar.messenger)
    updateChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "checkForUpdates" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.updaterController.checkForUpdates(nil)
      result(true)
    }
    appUpdateInstallerChannel = updateChannel

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

  private func transferBackup(from source: URL, to destination: URL, importing: Bool, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let selected = importing ? source : destination
      let scoped = selected.startAccessingSecurityScopedResource()
      defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
      do {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try data.write(to: destination, options: .atomic)
        DispatchQueue.main.async {
          self.backupPickerOpen = false
          result(importing ? destination.path as Any : true)
        }
      } catch {
        if importing { try? FileManager.default.removeItem(at: destination) }
        DispatchQueue.main.async {
          self.backupPickerOpen = false
          result(FlutterError(code: "FILE_COPY", message: "Unable to copy backup (limit 128 MB).", details: nil))
        }
      }
    }
  }

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
