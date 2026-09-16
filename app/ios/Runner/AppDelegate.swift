import Flutter
import Security
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var externalLinksChannel: FlutterMethodChannel?
  private var appVersionChannel: FlutterMethodChannel?
  private var accountSessionChannel: FlutterMethodChannel?
  private var backupFilesChannel: FlutterMethodChannel?
  private var backupResult: FlutterResult?
  private var exportingBackup = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "ExternalLinkLauncher"
    ) else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/external_links",
      binaryMessenger: registrar.messenger()
    )
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
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }
    externalLinksChannel = channel

    let backupChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/backup_files", binaryMessenger: registrar.messenger())
    backupChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard call.method == "pickBackup" || call.method == "saveBackup" else {
        result(FlutterMethodNotImplemented); return
      }
      guard self.backupResult == nil else {
        result(FlutterError(code: "BUSY", message: "A document picker is already open.", details: nil)); return
      }
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
      guard var presenter = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        result(FlutterError(code: "FILE_PICKER", message: "No active window.", details: nil)); return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      let picker: UIDocumentPickerViewController
      self.exportingBackup = call.method == "saveBackup"
      if self.exportingBackup {
        guard let path = call.arguments as? String else {
          result(FlutterError(code: "INVALID_PATH", message: "Backup path is missing.", details: nil)); return
        }
        if #available(iOS 14.0, *) {
          picker = UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: path)], asCopy: true)
        } else {
          picker = UIDocumentPickerViewController(url: URL(fileURLWithPath: path), in: .exportToService)
        }
      } else {
        if #available(iOS 14.0, *) {
          picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        } else {
          picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
        }
      }
      self.backupResult = result
      picker.delegate = self
      picker.allowsMultipleSelection = false
      presenter.present(picker, animated: true)
    }
    backupFilesChannel = backupChannel

    let versionChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/app_version",
      binaryMessenger: registrar.messenger()
    )
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

    let accountChannel = FlutterMethodChannel(
      name: "io.github.troyt666.jfzreader/account_session",
      binaryMessenger: registrar.messenger()
    )
    accountChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "read":
        do {
          result(try Self.readAccountSession())
        } catch {
          result(Self.accountStorageError())
        }
      case "write":
        guard let value = call.arguments as? String else {
          result(
            FlutterError(
              code: "INVALID_VALUE",
              message: "Session must be text.",
              details: nil
            )
          )
          return
        }
        do {
          try Self.writeAccountSession(value)
          result(nil)
        } catch {
          result(Self.accountStorageError())
        }
      case "clear":
        do {
          try Self.clearAccountSession()
          result(nil)
        } catch {
          result(Self.accountStorageError())
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    accountSessionChannel = accountChannel
  }

  private static let accountService = "io.github.troyt666.jfzreader.account"

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = backupResult
    backupResult = nil
    result?(exportingBackup ? false : nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = backupResult else { return }
    if exportingBackup { backupResult = nil; result(!urls.isEmpty); return }
    guard let source = urls.first else { backupResult = nil; result(nil); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let scoped = source.startAccessingSecurityScopedResource()
      defer { if scoped { source.stopAccessingSecurityScopedResource() } }
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("jfz-backup-import-\(UUID().uuidString).jfzbackup")
      do {
        // Coordinate reads from Files/iCloud providers before copying to app cache.
        var coordinationError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
          do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            try data.write(to: destination, options: .atomic)
          } catch { readError = error }
        }
        if let error = coordinationError ?? readError as NSError? { throw error }
        DispatchQueue.main.async { self.backupResult = nil; result(destination.path) }
      } catch {
        try? FileManager.default.removeItem(at: destination)
        DispatchQueue.main.async {
          self.backupResult = nil
          result(FlutterError(code: "FILE_COPY", message: "Unable to copy backup (limit 128 MB).", details: nil))
        }
      }
    }
  }
  private static let accountName = "session-v1"

  private static func accountQuery() -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: accountService,
      kSecAttrAccount as String: accountName,
    ]
  }

  private static func readAccountSession() throws -> String? {
    var query = accountQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw AccountStorageFailure.failed
    }
    return value
  }

  private static func writeAccountSession(_ value: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw AccountStorageFailure.failed
    }
    let query = accountQuery()
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw AccountStorageFailure.failed
    }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw AccountStorageFailure.failed
    }
  }

  private static func clearAccountSession() throws {
    let status = SecItemDelete(accountQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AccountStorageFailure.failed
    }
  }

  private static func accountStorageError() -> FlutterError {
    return FlutterError(
      code: "SECURE_STORAGE",
      message: "The Keychain account session could not be accessed.",
      details: nil
    )
  }

  private enum AccountStorageFailure: Error {
    case failed
  }
}
