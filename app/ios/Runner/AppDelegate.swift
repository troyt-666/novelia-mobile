import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var externalLinksChannel: FlutterMethodChannel?
  private var accountSessionChannel: FlutterMethodChannel?

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
