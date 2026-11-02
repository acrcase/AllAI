import Cocoa
import FlutterMacOS
import Security

/// `allai/keychain`: "Safe Storage" parolasını AllAI'nin KENDİ imzalı sürecinden okur.
///
/// `/usr/bin/security` aracı KULLANILMAZ: aksi hâlde "Her Zaman İzin Ver" erişimi o araca (yani
/// kullanıcının her sürecine) verilirdi. Burada ACL AllAI ikilisine aittir. Parola yalnız Flutter'a
/// döner, bir daha okunmaz, loglanmaz. Yalnız kullanıcı onayından sonra çağrılır.
final class KeychainChannel {
  private let channel: FlutterMethodChannel

  // Yalnız bu "Safe Storage" öğeleri okunabilir; başka hiçbir anahtarlık adı kabul edilmez.
  private static let allowedServices: Set<String> = ["Claude Safe Storage", "Chrome Safe Storage"]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "allai/keychain", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "safeStoragePassword",
            let args = call.arguments as? [String: Any],
            let service = args["service"] as? String,
            KeychainChannel.allowedServices.contains(service)
      else { return result(nil) }
      // Erişim penceresi/sorgu ana iş parçacığını bloklamasın.
      DispatchQueue.global(qos: .userInitiated).async {
        // Yalnız kSecAttrService ile sorgulanır; hesap adı varsayılmaz.
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecReturnData as String: true,
          kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var password: String?
        if status == errSecSuccess, let data = item as? Data {
          password = String(data: data, encoding: .utf8)
        }
        // Bulunamadı / yetki reddi / kullanıcı iptali: sessizce nil.
        DispatchQueue.main.async { result(password) }
      }
    }
  }
}

/// `allai/window`: Flutter'ın çizdiği üst çubuktan pencereyi sürükleme ve büyütme.
final class WindowChannel {
  private weak var window: NSWindow?
  private weak var dock: AppDockController?
  private let channel: FlutterMethodChannel
  private var lastMouseDown: NSEvent?
  private var monitor: Any?
  private var frameBeforeFill: NSRect?

  init(window: NSWindow, messenger: FlutterBinaryMessenger, dock: AppDockController?) {
    self.window = window
    self.dock = dock
    channel = FlutterMethodChannel(name: "allai/window", binaryMessenger: messenger)
    // performDrag bir mouseDown olayı ister; Flutter'ın pan başlangıcı geldiğinde son basış kullanılır.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      if event.window === self?.window { self?.lastMouseDown = event }
      return event
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, let window = self.window else { return result(nil) }
      switch call.method {
      case "startDrag":
        self.startDrag(window)
        result(nil)
      case "toggleZoom":
        self.toggleZoom(window)
        result(nil)
      case "isFullScreen":
        result(window.styleMask.contains(.fullScreen))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  /// Yerleşikken sürüklemeyi AppDockController yürütür (hedef pencere aynı adımda taşınır).
  private func startDrag(_ window: NSWindow) {
    guard let down = lastMouseDown, NSEvent.pressedMouseButtons & 1 == 1 else { return }
    if dock?.beginDrag(down) == true { return }
    window.performDrag(with: down)
  }

  /// Başlığa çift tıklama: Sistem Ayarları > Masaüstü ve Dock > "Pencere başlık çubuğuna çift tıkla".
  private func toggleZoom(_ window: NSWindow) {
    let defaults = UserDefaults.standard
    switch defaults.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      window.miniaturize(nil)
    case "None", "No Action":
      break
    case "Fill":
      fill(window)
    case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
      window.miniaturize(nil)
    default:
      window.zoom(nil)
    }
  }

  private func fill(_ window: NSWindow) {
    guard let visible = window.screen?.visibleFrame else { return }
    let filled = abs(window.frame.minX - visible.minX) < 2 && abs(window.frame.minY - visible.minY) < 2
      && abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
    if filled, let old = frameBeforeFill {
      frameBeforeFill = nil
      window.setFrame(old, display: true, animate: true)
    } else if !filled {
      frameBeforeFill = window.frame
      window.setFrame(visible, display: true, animate: true)
    }
  }
}

/// Yerel "Git" menüsü: WKWebView odaktayken de çalışan kısayollar, `allai/menu` ile Flutter'a gider.
final class GoMenu: NSObject {
  private let channel: FlutterMethodChannel
  private let menu = NSMenu(title: "Go")
  private var serviceItems: [NSMenuItem] = []
  private var rootItem: NSMenuItem?
  private var itemsByAction: [String: NSMenuItem] = [:]
  private var serviceFormat = "AI #{n}"
  private var serviceNames: [String] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "allai/menu", binaryMessenger: messenger)
    super.init()
    menu.autoenablesItems = false
    add("Home", "0", "home")
    add("Reload", "r", "reload")
    menu.addItem(.separator())
    add("Back", "[", "back")
    add("Forward", "]", "forward")
    menu.addItem(.separator())
    for i in 0..<9 {
      serviceItems.append(add(serviceTitle(i), "\(i + 1)", "open", tag: i))
    }
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setServiceNames":
        self?.setServiceNames(call.arguments as? [String] ?? [])
        result(nil)
      case "setLabels":
        self?.setLabels(call.arguments as? [String: String] ?? [:])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // Ana menü nib yüklemesi bitince atanır.
    DispatchQueue.main.async { [weak self] in self?.install() }
  }

  private func install() {
    guard let main = NSApp.mainMenu else { return }
    let root = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
    root.submenu = menu
    rootItem = root
    let windowIndex = main.items.firstIndex { $0.submenu != nil && $0.submenu === NSApp.windowsMenu }
    main.insertItem(root, at: windowIndex ?? main.items.count)
  }

  @discardableResult
  private func add(_ title: String, _ key: String, _ action: String, tag: Int = -1) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: key)
    item.target = self
    item.representedObject = action
    item.tag = tag
    if tag < 0 { itemsByAction[action] = item }
    menu.addItem(item)
    return item
  }

  @objc private func choose(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? String else { return }
    channel.invokeMethod(action, arguments: action == "open" ? sender.tag : nil)
  }

  /// Kart sırasındaki adlar; fazlası gizlenir (gizli öğenin kısayolu da kapanır).
  private func setServiceNames(_ names: [String]) {
    serviceNames = names
    for (i, item) in serviceItems.enumerated() {
      let has = i < names.count
      item.title = has ? names[i] : serviceTitle(i)
      item.isHidden = !has
      item.isEnabled = has
    }
  }

  private func serviceTitle(_ i: Int) -> String {
    serviceFormat.replacingOccurrences(of: "{n}", with: "\(i + 1)")
  }

  /// Dart'tan gelen yerelleşmiş etiketler: go, home, reload, back, forward, service ("{n}" yer tutucu).
  private func setLabels(_ labels: [String: String]) {
    if let go = labels["go"], !go.isEmpty {
      menu.title = go
      rootItem?.title = go
    }
    for action in ["home", "reload", "back", "forward"] {
      if let title = labels[action], !title.isEmpty { itemsByAction[action]?.title = title }
    }
    if let f = labels["service"], !f.isEmpty { serviceFormat = f }
    setServiceNames(serviceNames)
  }
}
