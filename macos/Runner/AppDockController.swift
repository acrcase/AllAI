import ApplicationServices
import Cocoa
import FlutterMacOS
import ScreenCaptureKit

/// Kurulu bir uygulamanın ana penceresini bizim penceredeki saydam "delik"in üstüne oturtur.
/// Başka sürecin penceresi gömülemez; Erişilebilirlik (AX) ile konumlandırılıp orada tutulur.
/// Her kart (`key`) bir sürece bağlanır: aynı uygulamanın ayrı profilli örnekleri ayrı kartlardır.
final class AppDockController: NSObject, FlutterStreamHandler {
  private enum Pause { case fullScreen, miniaturized, appHidden }

  /// Bir kartın süreci. `ours`: AllAI başlattı, bırakılınca kapatılır. Değilse `restore`
  /// (yerleştirme öncesi çerçeve, AX koordinatı) geri konur. `webWindow`: sahibin Chrome'unda açtığımız
  /// `--app` penceresi; süreç sahibin, yalnız bu pencere bizim (gizlenmez/kapanmaz, pencere kapatılır).
  private final class Instance {
    let app: NSRunningApplication
    var ours: Bool
    var window: AXUIElement?
    var restore: CGRect?
    let webWindow: Bool
    /// Chrome penceresinin pencere sunucusundaki kimliği: her taşıma/kapatma öncesi yeniden doğrulanır.
    var windowId: CGWindowID?
    init(_ app: NSRunningApplication, ours: Bool, webWindow: Bool = false) {
      self.app = app
      self.ours = ours
      self.webWindow = webWindow
    }
  }

  private static let chrome = "com.google.Chrome"

  /// Bir yerleştirme isteği; `profile`: ikinci hesabın veri klasörü.
  private struct Request {
    let key: String
    let bundleId: String
    let url: URL
    let profile: URL?
  }

  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var sink: FlutterEventSink?

  // Delik, içerik kenarlarına uzaklık olarak tutulur: canlı boyutlanmada Flutter yeni
  // rect'i göndermeden de hedef doğru boyutta izler.
  private var insets = NSEdgeInsets()
  private var hasHole = false

  private var instances: [String: Instance] = [:]
  private var target: NSRunningApplication?
  private var targetKey: String?
  private var targetWindow: AXUIElement?
  private var observer: AXObserver?
  /// Açılan uygulamanın "pencere oluştu" gözlemcisi: pencere yoklamayı (150 ms) beklemeden, oluştuğu
  /// anda deliğe taşınır; kendi kayıtlı yerinde görünmez.
  private var launchObserver: (pid: pid_t, observer: AXObserver)?
  private var monitors: [Any] = []
  private var dragMonitor: Any?
  private var drag: (origin: NSPoint, grab: NSPoint, pointer: () -> NSPoint)?
  private var dragLink: AnyObject?
  // Örtü: sürükleme/boyutlanmada delik kapanır, hedef altta yerine oturur (bkz. coverOn).
  private var covered = false
  private var coverGen = 0
  private var coverTargetId: CGWindowID?
  private var coverView: NSImageView?
  /// Önceden alınmış görüntü: almak bu Mac'te 200-350 ms sürüyor, sürükleme başlayınca istenirse
  /// kısa sürüklemede hiç yetişmez. İmleç çubuğa ya da kenara yaklaşınca alınır (bkz. prepareSnapshot).
  private var ready: (id: CGWindowID, image: CGImage, at: CFTimeInterval)?
  private var preparing = false
  /// Hedef pencerenin yakalama süzgeci (pencere listesini almak ayrıca ~75 ms).
  private var filterCache: (id: CGWindowID, filter: AnyObject)?
  private var lastPlaced: CGRect?
  private var acceptedSize: CGSize?
  private var paused: Set<Pause> = []
  private var savedBehavior: NSWindow.CollectionBehavior?
  private var fullScreenBusy = false
  private var generation = 0
  private var pendingKey: String?
  /// Açılışı süren kartlar ve açılıştan önce çalışan pid'ler: bunların dışında beliren süreç AllAI'nindir
  /// (tamamlanma bloğu gelmeden AllAI kapanırsa da).
  private var launching: [String: (bundleId: String, profile: String?, before: Set<pid_t>)] = [:]
  /// Kapatma isteği gönderilmiş süreçler: kapanana dek yeniden seçilmez.
  private var terminating: Set<pid_t> = []
  /// Süreci kapanınca silinecek profil klasörleri (Electron kapanırken çerezleri yeniden yazar).
  /// AllAI önce kapanırsa diye kalıcı listede de tutulur, sonraki açılışta temizlenir.
  private var pendingDeletes: [pid_t: URL] = [:]
  private static let pendingDeletesKey = "AllAIPendingProfileDeletes"
  /// Süren Chrome açılışı (aynı anda tek: iki açılış birbirinin penceresini sahiplenmesin) ve sıradakiler.
  private var webLaunch: (key: String, before: Set<CGWindowID>, pid: pid_t?)?
  private var webQueue: [() -> Void] = []
  private var webObserver: AXObserver?
  private var webObserverPid: pid_t?
  /// close(key) ile artar: kapatılmış sekmenin açılışı sonradan biterse süreç sahiplenilmez, kapatılır.
  private var closeEpochs: [String: Int] = [:]
  private var snapWork: DispatchWorkItem?
  private var deferred: (inst: Instance, work: DispatchWorkItem)?
  private var lostWork: DispatchWorkItem?
  private var lostApp: NSRunningApplication?
  private var tokens: [NSObjectProtocol] = []

  // Yalnız profil/hata ayıklama (Dart `kReleaseMode` dışında `debugHooks` gönderir).
  private var profilesOverride: URL?
  private var dragTestPending = false
  private var debugLog = false

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "allai/dock", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(name: "allai/dock/events", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      self.handle(call, result)
    }
    eventChannel.setStreamHandler(self)
    observe(window)
    DispatchQueue.main.async { [weak self] in self?.removeLeftoverProfiles() }
  }

  deinit {
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
    tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
  }

  // MARK: Kanal

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isTrusted":
      let prompt = args["prompt"] as? Bool ?? false
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
      result(AXIsProcessTrustedWithOptions(options))
    case "openAccessibilitySettings":
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
      }
      result(nil)
    case "isInstalled":
      let id = args["bundleId"] as? String ?? ""
      result(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil)
    case "webInChrome":
      result(NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chrome) != nil)
    case "supportsProfiles":
      let id = args["bundleId"] as? String ?? ""
      result(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map(Self.isElectron) ?? false)
    case "dock":
      guard let key = args["key"] as? String, let id = args["bundleId"] as? String, let rect = Self.rect(args) else {
        result(FlutterError(code: "bad_args", message: "key, bundleId ve rect gerekli", details: nil))
        return
      }
      dock(key, id, profile: args["separateProfile"] as? Bool ?? false, rect) { result($0) }
    case "dockWeb":
      guard let key = args["key"] as? String, let url = args["url"] as? String, let rect = Self.rect(args) else {
        result(FlutterError(code: "bad_args", message: "key, url ve rect gerekli", details: nil))
        return
      }
      dockWeb(key, url, rect) { result($0) }
    case "close":
      close(args["key"] as? String ?? "")
      result(nil)
    case "deleteProfile":
      deleteProfile(args["key"] as? String ?? "") { result(nil) }
    case "updateRect":
      setHole(Self.rect(args) ?? .zero)
      place()
      updateThrough()
      result(nil)
    case "hide":
      hide(keep: args["keep"] as? Bool ?? false)
      result(nil)
    case "debugHooks":
      if let dir = args["profilesDir"] as? String, !dir.isEmpty {
        profilesOverride = URL(fileURLWithPath: dir, isDirectory: true)
      }
      dragTestPending = args["dragTest"] as? Bool ?? false
      debugLog = dragTestPending
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func rect(_ args: [String: Any]) -> CGRect? {
    guard let x = args["x"] as? Double, let y = args["y"] as? Double,
          let w = args["width"] as? Double, let h = args["height"] as? Double else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private func emit(_ type: String, _ key: String?, _ bundleId: String?, _ message: String? = nil) {
    var event: [String: Any] = ["type": type]
    if let key { event["key"] = key }
    if let bundleId { event["bundleId"] = bundleId }
    if let message { event["message"] = message }
    sink?(event)
  }

  // MARK: Yerleştirme

  private func dock(_ key: String, _ bundleId: String, profile: Bool, _ rect: CGRect,
                    done: @escaping (String) -> Void) {
    guard AXIsProcessTrusted() else { return done("needsPermission") }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
      return done("notInstalled")
    }
    var dir: URL?
    if profile {
      guard Self.isElectron(url), let d = profileDir(key) else {
        emit("error", key, bundleId, "err.secondAccountUnsupported")
        return done("failed")
      }
      dir = d
    }
    let req = Request(key: key, bundleId: bundleId, url: url, profile: dir)
    generation += 1
    pendingKey = key
    let previous = targetKey.flatMap { instances[$0] } ?? takeDeferred()
    undock()
    setHole(rect)
    leaveFullScreen(key, bundleId)
    let running = runningApp(req)
    // Önceki sekmenin örneği yalnız kendi sürecinde (Chrome penceresi ekran dışında) gizlenir, kapanmaz;
    // yeni pencere yerleşince (attach).
    if let previous, previous.webWindow || previous.app.processIdentifier != running?.processIdentifier {
      deferConceal(previous)
    }
    // Gizli uygulamanın penceresi görünmeden önce deliğe oturtulur: kendi boyutunda belirip küçülmez.
    if let running, let win = instances[key]?.window, let want = holeAX() {
      axSetSize(win, want.size)
      axSetPoint(win, want.origin)
      axSetSize(win, want.size)
    }
    if let running, running.isHidden { running.unhide() }
    if running == nil { launch(req, adopt: true) }
    poll(req, gen: generation, start: Date(), opened: running == nil, done: done)
  }

  private func poll(_ req: Request, gen: Int, start: Date, opened: Bool, done: @escaping (String) -> Void) {
    guard gen == generation else { return cancelled(req, done) }
    guard Date().timeIntervalSince(start) < 15 else { return done("failed") }
    let retry = { [weak self] (opened: Bool) in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        self?.poll(req, gen: gen, start: start, opened: opened, done: done)
      }
    }
    let busy = fullScreenBusy || (window?.styleMask.contains(.fullScreen) ?? false)
    guard let app = runningApp(req), !busy else { return retry(opened) }
    if opened { watchLaunch(app.processIdentifier) }

    // AX sorgusu açılıştaki yavaş uygulamayı bekleyebilir; arayüz iş parçacığında yapılmaz.
    let pid = app.processIdentifier
    DispatchQueue.global(qos: .userInitiated).async {
      let found = findStandardWindow(pid)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard gen == self.generation else { return self.cancelled(req, done) }
        guard let win = found else {
          // Çalışıyor ama penceresi yok: yeniden açma olayı çoğu uygulamada pencere açtırır.
          if !opened { self.launch(req, adopt: false) }
          return retry(true)
        }
        if axBool(win, kAXMinimizedAttribute) == true { axSetBool(win, kAXMinimizedAttribute, false) }
        if axBool(win, "AXFullScreen") == true {
          axSetBool(win, "AXFullScreen", false)
          return retry(opened)
        }
        self.attach(req.key, app, win)
        done("docked")
      }
    }
  }

  /// Açılırken vazgeçildi (başka dock ya da hide): yeni hedef değilse ortada kalmasın.
  /// Kapatılan kartın kaydı silinmiştir; yeniden kaydedilmez.
  private func cancelled(_ req: Request, _ done: (String) -> Void) {
    if pendingKey != req.key, targetKey != req.key, let inst = instances[req.key],
       inst.app.processIdentifier != target?.processIdentifier {
      conceal(inst)
    }
    done("idle")
  }

  /// Hedef pencere bizim tam ekran alanımıza giremez: önce pencere kipine dön.
  private func leaveFullScreen(_ key: String, _ bundleId: String) {
    guard let window, window.styleMask.contains(.fullScreen) else { return }
    window.toggleFullScreen(nil)
    emit("fullscreenUnsupported", key, bundleId)
  }

  /// Sekmeden çıkılan örnek gizlenir. Chrome penceresinde uygulama gizlenemez (sahibin bütün
  /// pencereleri gizlenir) ve küçültme Dock'a uçar: pencere bir ekran köşesinin dışına taşınır.
  /// Klavye odağı sahibin en öndeki kendi Chrome penceresine verilir (⌘Tab ile yazılanlar oraya gitsin).
  private func conceal(_ inst: Instance?) {
    guard let inst else { return }
    guard inst.webWindow else {
      inst.app.hide()
      return
    }
    guard let win = verifiedWindow(inst), let size = axSize(win), let at = concealPoint(size) else { return }
    axSetPoint(win, at)
    let ax = AXUIElementCreateApplication(inst.app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.3)
    let ours = instances.values.compactMap(\.window)
    if let own = axWindows(ax)?.first(where: { w in !ours.contains { CFEqual($0, w) } }) {
      axSetBool(own, kAXMainAttribute, true)
    }
  }

  /// Bizim ekranın bir köşesi; pencerenin taşacağı alan başka bir ekranla kesişmesin (AX koordinatı).
  private func concealPoint(_ size: CGSize) -> CGPoint? {
    guard let primary = NSScreen.screens.first, let screen = window?.screen ?? NSScreen.main else { return nil }
    let ax = { (r: NSRect) in CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height) }
    let f = ax(screen.frame), others = NSScreen.screens.filter { $0 != screen }.map { ax($0.frame) }
    let corners = [CGPoint(x: f.maxX - 1, y: f.maxY - 1), CGPoint(x: f.minX - size.width + 1, y: f.maxY - 1),
                   CGPoint(x: f.maxX - 1, y: f.minY - size.height + 1), CGPoint(x: f.minX - size.width + 1, y: f.minY - size.height + 1)]
    return corners.first { c in !others.contains { $0.intersects(CGRect(origin: c, size: size)) } } ?? corners[0]
  }

  // MARK: Web kartı: sahibin Chrome'unda uygulama penceresi

  private enum WindowState { case alive, dead, unknown }

  /// Pencere hâlâ bizim açtığımız pencere mi: AX nesnesi geçerli ve pencere sunucusunda aynı kimlik
  /// Chrome'a ait. Zaman aşımı "ölü" sayılmaz (yeni pencere açılıp eskisi öksüz kalmasın).
  private func windowState(_ inst: Instance) -> WindowState {
    guard let win = inst.window, let id = inst.windowId else { return .dead }
    guard let info = Self.windowInfo(id), (info[kCGWindowOwnerPID as String] as? pid_t) == inst.app.processIdentifier else {
      return .dead
    }
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &value) {
    case .success: return .alive
    case .invalidUIElement: return .dead
    default: return .unknown
    }
  }

  private func verifiedWindow(_ inst: Instance) -> AXUIElement? {
    windowState(inst) == .alive ? inst.window : nil
  }

  /// Web kartı Chrome `--app` penceresiyle açılır (oturum sahibin Chrome profilinde; çerez okunmaz).
  /// Sahibin ⌘H ile gizlediği Chrome gösterilmez (bütün pencereleri görünür olurdu): "failed".
  private func dockWeb(_ key: String, _ url: String, _ rect: CGRect, done: @escaping (String) -> Void) {
    guard AXIsProcessTrusted() else { return done("needsPermission") }
    guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chrome) else {
      return done("notInstalled")
    }
    generation += 1
    pendingKey = key
    let previous = targetKey.flatMap { instances[$0] } ?? takeDeferred()
    undock()
    setHole(rect)
    leaveFullScreen(key, Self.chrome)
    if let previous, previous !== instances[key] { deferConceal(previous) }
    if Self.chromeApp()?.isHidden == true {
      emit("error", key, Self.chrome, "err.chromeHidden")
      return done("failed")
    }
    if let inst = instances[key] {
      switch windowState(inst) {
      case .alive:
        return reuse(key, inst, gen: generation, done: done)
      case .unknown:
        emit("error", key, Self.chrome, "err.chromeUnresponsive")
        return done("failed")
      case .dead:
        forget(key)
      }
    }
    launchWeb(key, url, chromeURL, gen: generation, done: done)
  }

  /// Var olan pencere: küçültülmüşse açılır, tam ekransa pencere kipine döner, sonra yerleşir.
  private func reuse(_ key: String, _ inst: Instance, gen: Int, done: @escaping (String) -> Void) {
    guard let win = inst.window else { return done("failed") }
    if axBool(win, kAXMinimizedAttribute) == true { axSetBool(win, kAXMinimizedAttribute, false) }
    let full = axBool(win, "AXFullScreen") == true
    if full { axSetBool(win, "AXFullScreen", false) }
    DispatchQueue.main.asyncAfter(deadline: .now() + (full ? 1.0 : 0)) { [weak self] in
      guard let self, gen == self.generation, self.verifiedWindow(inst) != nil else { return done("idle") }
      self.attach(key, inst.app, win)
      done("docked")
    }
  }

  /// Açılışlar sıradadır: öncesi listesi (bütün Space'lerden, pencere sunucusu) bir öncekinin
  /// penceresi kaydedildikten sonra alınır.
  private func launchWeb(_ key: String, _ url: String, _ chromeURL: URL, gen: Int, done: @escaping (String) -> Void) {
    guard webLaunch == nil else {
      webQueue.append { [weak self] in self?.launchWeb(key, url, chromeURL, gen: gen, done: done) }
      return
    }
    // Sırada beklerken vazgeçildiyse pencere hiç açılmaz.
    guard gen == generation else { return done("idle") }
    let pid = Self.chromeApp()?.processIdentifier
    let before = Self.chromeWindowIds(pid)
    webLaunch = (key, before, pid)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.arguments = ["--app=\(url)"]
    // Pencere varsayılan yerinde (solda) açılıp sonradan taşınmasın: doğrudan deliğin yerinde ve boyutunda açılır.
    if let hole = holeAX() {
      config.arguments += ["--window-position=\(Int(hole.minX)),\(Int(hole.minY))",
                            "--window-size=\(Int(hole.width)),\(Int(hole.height))"]
    }
    config.createsNewApplicationInstance = pid != nil
    NSWorkspace.shared.openApplication(at: chromeURL, configuration: config) { _, _ in }
    // Pencere oluştuğu anda deliğe taşınır (bayraklar yok sayılsa da solda görünmez).
    if let pid { watchLaunch(pid) }
    pollWeb(key, gen: gen, epoch: closeEpochs[key, default: 0], before: before, start: Date(), seen: nil, done: done)
  }

  private func finishWebLaunch() {
    webLaunch = nil
    stopLaunchWatch()
    if !webQueue.isEmpty { webQueue.removeFirst()() }
  }

  /// Yeni pencere: açılıştan önce olmayan, başka kayda ait olmayan TEK Chrome penceresi; iki ardışık
  /// yoklamada aynı kalmalı ve AX'te aynı çerçeveyle bulunmalı. Birden çoksa (sahibin ⌘N'i, açılır
  /// pencere, oturum geri yükleme) hangisinin bizim olduğu kesin değildir: "failed", hiçbirine dokunulmaz.
  /// Vazgeçilirse (başka sekme, ana ekran) ya da 15 sn geçerse cevap döner; pencere 30 sn'ye kadar
  /// gelirse yine sahiplenilip gizlenir, sekme kapatıldıysa kapatılır.
  private func pollWeb(_ key: String, gen: Int, epoch: Int, before: Set<CGWindowID>, start: Date, seen: CGWindowID?,
                       done: ((String) -> Void)?) {
    var done = done
    func respond(_ state: String) {
      done?(state)
      done = nil
    }
    if gen != generation { respond("idle") }
    let elapsed = Date().timeIntervalSince(start)
    if elapsed > 15 { respond("failed") }
    guard elapsed < 30 else { return finishWebLaunch() }
    let retry = { [weak self] (seen: CGWindowID?) in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        self?.pollWeb(key, gen: gen, epoch: epoch, before: before, start: start, seen: seen, done: done)
      }
    }
    guard let app = Self.chromeApp() else { return retry(nil) }
    watchLaunch(app.processIdentifier)
    let owned = Set(instances.values.compactMap(\.windowId))
    let fresh = Self.chromeWindowIds(app.processIdentifier).subtracting(before).subtracting(owned)
    guard fresh.count <= 1 else {
      emit("error", key, Self.chrome, "err.chromeBusy")
      respond("failed")
      return finishWebLaunch()
    }
    guard let id = fresh.first, id == seen, let bounds = Self.windowInfo(id).flatMap(Self.bounds) else {
      return retry(fresh.first)
    }
    let pid = app.processIdentifier
    DispatchQueue.global(qos: .userInitiated).async {
      let ax = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(ax, 0.5)
      let windows = axWindows(ax)
      let matches = windows?.filter { axFrame($0) == bounds && axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // AX hatası boş liste sayılmaz: vazgeçilir.
        guard let matches else {
          respond("failed")
          return self.finishWebLaunch()
        }
        guard matches.count == 1, let win = matches.first else { return retry(id) }
        AXUIElementSetMessagingTimeout(win, 0.3)
        let inst = Instance(app, ours: true, webWindow: true)
        inst.window = win
        inst.windowId = id
        if self.closeEpochs[key, default: 0] != epoch {
          // Sekme açılış sürerken kapatıldı: doğrulanmış (tek yeni) pencere kapatılır.
          self.closeWeb(inst, key: key)
          respond("idle")
          return self.finishWebLaunch()
        }
        self.instances[key] = inst
        self.observeWeb(inst)
        if done == nil {
          self.conceal(inst)
        } else {
          self.attach(key, app, win)
          respond("docked")
        }
        self.finishWebLaunch()
      }
    }
  }

  /// Chrome açık kalır; yalnız açtığımız pencere kendi kapatma düğmesiyle kapanır. "Sayfadan ayrıl?"
  /// sorusu kapanmayı durdurursa pencere görünür yere gelip öne alınır, Flutter'a 'closeBlocked' gider.
  /// [wait]: AllAI kapanırken sonraki tur gelmez; soru beklenerek bakılır.
  private func closeWeb(_ inst: Instance, key: String, wait: Bool = false) {
    guard let win = verifiedWindow(inst), let button = axElement(win, kAXCloseButtonAttribute) else { return }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    let check = { [weak self] in
      guard let self, self.windowState(inst) == .alive, let screen = self.window?.screen ?? NSScreen.main,
            let primary = NSScreen.screens.first, let size = axSize(win) else { return }
      let v = screen.visibleFrame
      axSetPoint(win, CGPoint(x: (v.midX - size.width / 2).rounded(), y: (primary.frame.maxY - v.midY - size.height / 2).rounded()))
      axSetBool(win, kAXMainAttribute, true)
      AXUIElementPerformAction(win, kAXRaiseAction as CFString)
      self.activate(inst.app)
      self.emit("closeBlocked", key, Self.chrome)
    }
    if wait {
      for _ in 0..<10 where windowState(inst) == .alive { usleep(50_000) }
      check()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
    }
  }

  /// Kaydı ve kapanma gözlemini bırakır.
  private func forget(_ key: String) {
    guard let inst = instances.removeValue(forKey: key) else { return }
    if inst.webWindow, let observer = webObserver, let win = inst.window {
      AXObserverRemoveNotification(observer, win, kAXUIElementDestroyedNotification as CFString)
    }
  }

  /// Her Chrome penceresi kapanma için izlenir: gizliyken sahip kapatırsa kayıt bayat kalmasın.
  private func observeWeb(_ inst: Instance) {
    let pid = inst.app.processIdentifier
    if webObserverPid != pid {
      if let webObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(webObserver), .defaultMode) }
      var created: AXObserver?
      guard AXObserverCreate(pid, webAxCallback, &created) == .success, let created else { return }
      CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
      webObserver = created
      webObserverPid = pid
    }
    guard let observer = webObserver, let win = inst.window else { return }
    AXObserverAddNotification(observer, win, kAXUIElementDestroyedNotification as CFString,
                              Unmanaged.passUnretained(self).toOpaque())
  }

  fileprivate func webWindowDestroyed(_ element: AXUIElement) {
    guard let (key, _) = instances.first(where: { $0.value.webWindow && $0.value.window.map { CFEqual($0, element) } == true })
    else { return }
    // Yerleşik pencereyse hedef gözlemcisi de bildirir; ilk gelen işler.
    if targetKey == key { undock() }
    forget(key)
    emit("terminated", key, Self.chrome)
  }

  private static func chromeApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: chrome).first { !$0.isTerminated }
  }

  /// Chrome'un bütün Space'lerdeki (tam ekran dahil) normal katman pencereleri, pencere sunucusundan.
  private static func chromeWindowIds(_ pid: pid_t?) -> Set<CGWindowID> {
    guard let pid else { return [] }
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(list.compactMap { info -> CGWindowID? in
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
            let b = bounds(info), b.width > 200, b.height > 150 else { return nil }
      return info[kCGWindowNumber as String] as? CGWindowID
    })
  }

  /// Kartın çalışan süreci: kayıtlı örnek, yoksa komut satırındaki `--user-data-dir` ile bulunur.
  /// Profilsiz kart profil örneklerini seçmez. Böyle bulunan örnek bu oturumda başlatılmadı
  /// (önceki oturumdan kalan profil örneği de): bırakılınca kapatılmaz, eski yerine döner.
  private func runningApp(_ req: Request) -> NSRunningApplication? {
    if let inst = instances[req.key], !inst.app.isTerminated { return inst.app }
    instances[req.key] = nil
    let want = req.profile?.path
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: req.bundleId).first(where: {
      !$0.isTerminated && !terminating.contains($0.processIdentifier) && Self.userDataDir($0.processIdentifier) == want
    }) else { return nil }
    // Aynı süreci başka kart bu oturumda açtıysa onun kaydı geçer; açılışı süren kartta açılıştan
    // önce olmayan süreç bizimdir.
    let pid = app.processIdentifier
    let ours = sameProcess(app).first?.ours ?? (launching[req.key].map { !$0.before.contains(pid) } ?? false)
    instances[req.key] = Instance(app, ours: ours)
    return app
  }

  private func sameProcess(_ app: NSRunningApplication) -> [Instance] {
    instances.values.filter { $0.app.processIdentifier == app.processIdentifier }
  }

  /// Uygulamayı açar. Başka örneği çalışan Electron uygulamasında yeni süreç istenir (yoksa
  /// LaunchServices çalışanı öne getirir). Penceresiz çalışan örnekte (`adopt: false`) yeni süreç
  /// aynı veri klasörünün kilidini görür, çalışana pencere açtırıp kapanır.
  private func launch(_ req: Request, adopt: Bool) {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    if let dir = req.profile {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      config.arguments = ["--user-data-dir=\(dir.path)"]
    }
    let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: req.bundleId).map(\.processIdentifier))
    config.createsNewApplicationInstance = Self.isElectron(req.url) && !before.isEmpty
    if adopt { launching[req.key] = (req.bundleId, req.profile?.path, before) }
    let epoch = closeEpochs[req.key, default: 0]
    NSWorkspace.shared.openApplication(at: req.url, configuration: config) { [weak self] app, _ in
      guard adopt else { return }
      DispatchQueue.main.async { self?.adopt(req.key, app, epoch: epoch, before: before) }
    }
  }

  /// AllAI'nin başlattığı süreç: kapatılırken sonlandırılacak. Sekme açılış sürerken kapatıldıysa hemen kapanır.
  /// LaunchServices zaten çalışan örneği döndürebilir (kullanıcı o an kendisi açtı): o bizim değil.
  private func adopt(_ key: String, _ app: NSRunningApplication?, epoch: Int, before: Set<pid_t>) {
    if launching[key]?.before == before { launching[key] = nil }
    guard let app, !before.contains(app.processIdentifier) else { return }
    if closeEpochs[key, default: 0] != epoch {
      if sameProcess(app).isEmpty { terminate(app) }
      return
    }
    if let inst = instances[key] {
      if inst.app.processIdentifier == app.processIdentifier { inst.ours = true }
    } else if !app.isTerminated {
      instances[key] = Instance(app, ours: true)
    }
  }

  /// Kapatma isteği iptal edilebilir ("Kaydet?"): 10 sn sonra süreç yeniden seçilebilir olur.
  private func terminate(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    terminating.insert(pid)
    app.terminate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.terminating.remove(pid) }
  }

  /// Süreç AX'e henüz hazır değilse kayıt tutmaz; bir sonraki yoklamada yeniden denenir.
  private func watchLaunch(_ pid: pid_t) {
    guard launchObserver?.pid != pid else { return }
    stopLaunchWatch()
    var created: AXObserver?
    guard AXObserverCreate(pid, launchAxCallback, &created) == .success, let created else { return }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard AXObserverAddNotification(created, app, kAXWindowCreatedNotification as CFString, refcon) == .success else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    launchObserver = (pid, created)
  }

  private func stopLaunchWatch() {
    if let launchObserver {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(launchObserver.observer), .defaultMode)
    }
    launchObserver = nil
  }

  /// Açılış sürerken yeni standart pencere: hemen deliğe. Yerleşimi (attach) yoklama yapar.
  fileprivate func launchWindowCreated(_ win: AXUIElement) {
    guard pendingKey != nil, targetWindow == nil, paused.isEmpty,
          axString(win, kAXSubroleAttribute) == kAXStandardWindowSubrole, let want = holeAX() else { return }
    // Önce konum: pencere yanlış yerden bir AX gidiş-dönüşü erken çıkar; boyut ekran kenarı
    // kısıtına takılırsa konum yeniden verilir.
    axSetPoint(win, want.origin)
    axSetSize(win, want.size)
    if axPoint(win) != want.origin { axSetPoint(win, want.origin) }
    log("açılış penceresi deliğe taşındı")
  }

  private func attach(_ key: String, _ app: NSRunningApplication, _ win: AXUIElement) {
    stopLaunchWatch()
    flushConceal()
    target = app
    targetKey = key
    targetWindow = win
    AXUIElementSetMessagingTimeout(win, 0.3)
    if let inst = instances[key] {
      inst.window = win
      if !inst.ours, inst.restore == nil {
        // Aynı pencereyi başka kart daha önce yerleştirdiyse ilk kayıt geçerlidir.
        inst.restore = sameProcess(app).compactMap(\.restore).first ?? axFrame(win)
      }
    }
    if let window {
      // Yerleşikken yeşil düğme tam ekran yerine büyütür; hedef aynı alanda kalabilir.
      // .transient: Mission Control'de bizim (ortası saydam) pencere ayrı küçük resim olmaz,
      // yalnız yerleşik uygulamanın penceresi görünür.
      savedBehavior = window.collectionBehavior
      window.collectionBehavior.subtract([.fullScreenPrimary, .managed, .stationary])
      window.collectionBehavior.formUnion([.fullScreenNone, .transient])
    }
    addObserver(app.processIdentifier, win)
    place(force: true)
    startTracking()
    axSetBool(win, kAXMainAttribute, true)
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    if NSApp.isActive || app.isActive { activate(app) }

    var message: String?
    if let want = lastPlaced, let size = acceptedSize,
       size.width > want.width + 1 || size.height > want.height + 1 {
      message = "oversize:\(Int(size.width))x\(Int(size.height))"
    }
    emit("docked", key, app.bundleIdentifier, message)
    if dragTestPending {
      dragTestPending = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.prepareSnapshot() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runDragTest() }
    }
  }

  private func undock() {
    stopLaunchWatch()
    uncover()
    snapWork?.cancel()
    lostWork?.cancel()
    lostApp = nil
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    observer = nil
    stopTracking()
    endDrag()
    window?.ignoresMouseEvents = false
    if let savedBehavior { window?.collectionBehavior = savedBehavior }
    savedBehavior = nil
    target = nil
    targetKey = nil
    targetWindow = nil
    ready = nil
    filterCache = nil
    lastPlaced = nil
    acceptedSize = nil
    paused = []
  }

  /// Ana ekrana dönüş: yerleşim bırakılır, örnek gizlenir ama kapanmaz.
  private func hide(keep: Bool = false) {
    generation += 1
    pendingKey = nil
    let current = targetKey.flatMap { instances[$0] }
    undock()
    if keep {
      deferConceal(current)
    } else {
      flushConceal()
      conceal(current)
    }
  }

  /// Karttan karta geçişte eski örnek, yenisi yerleşene (en çok 2 sn) kadar görünür kalır: delik boş
  /// kalmaz, eski pencere yenisinin altından çıkar.
  private func deferConceal(_ inst: Instance?) {
    flushConceal()
    guard let inst else { return }
    let work = DispatchWorkItem { [weak self] in self?.flushConceal() }
    deferred = (inst, work)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }

  /// Bekleyen eski örnek yeni yerleşime devredilir (gizleme zamanlayıcısı iptal).
  private func takeDeferred() -> Instance? {
    guard let d = deferred else { return nil }
    deferred = nil
    d.work.cancel()
    return d.inst
  }

  private func flushConceal() {
    guard let d = deferred else { return }
    deferred = nil
    d.work.cancel()
    conceal(d.inst)
  }

  /// Sekme kapatıldı. Olay gönderilmez; sonradan gelen sonlanma bildirimi de bu karta yazılmaz.
  private func close(_ key: String) {
    closeEpochs[key, default: 0] += 1
    if pendingKey == key {
      generation += 1
      pendingKey = nil
    }
    if targetKey == key { undock() }
    guard let inst = instances[key] else { return }
    forget(key)
    release(inst, key: key, hide: true)
  }

  /// AllAI kapanıyor: başlattığı örnekler kapanır, önceden açık olanlar eski çerçevesine dönüp gizlenir.
  private func releaseAll() {
    generation += 1
    pendingKey = nil
    undock()
    let all = instances
    instances = [:]
    var seen = Set<pid_t>()
    for (key, inst) in all where inst.webWindow || seen.insert(inst.app.processIdentifier).inserted {
      release(inst, key: key, hide: true, quitting: true)
    }
    // Süren Chrome açılışının penceresi gelmek üzere olabilir: en çok 1 sn beklenir, doğrulanan
    // tek yeni pencere kapatılır (öksüz kalmasın).
    if let launch = webLaunch {
      for _ in 0..<20 {
        let pid = launch.pid ?? Self.chromeApp()?.processIdentifier
        let fresh = Self.chromeWindowIds(pid).subtracting(launch.before)
        if fresh.count > 1 { break }
        if let id = fresh.first, let pid, let app = Self.chromeApp(), let b = Self.windowInfo(id).flatMap(Self.bounds) {
          let ax = AXUIElementCreateApplication(pid)
          AXUIElementSetMessagingTimeout(ax, 0.3)
          if let wins = axWindows(ax)?.filter({ axFrame($0) == b }), wins.count == 1 {
            let inst = Instance(app, ours: true, webWindow: true)
            inst.window = wins[0]
            inst.windowId = id
            closeWeb(inst, key: launch.key, wait: true)
          }
          break
        }
        usleep(50_000)
      }
    }
    // Tamamlanma bloğu gelmeden kapanıyoruz: açılıştan önce olmayan, aynı profildeki süreç AllAI'nindir.
    for l in launching.values {
      for app in NSRunningApplication.runningApplications(withBundleIdentifier: l.bundleId)
      where !l.before.contains(app.processIdentifier) && !seen.contains(app.processIdentifier)
        && Self.userDataDir(app.processIdentifier) == l.profile {
        terminate(app)
      }
    }
  }

  /// Örneği bırakır: AllAI başlattıysa kapatır (zorlamadan), değilse eski çerçevesine koyar.
  /// Aynı süreci kullanan başka kart varsa dokunulmaz.
  private func release(_ inst: Instance, key: String, hide: Bool, quitting: Bool = false) {
    if inst.webWindow { return closeWeb(inst, key: key, wait: quitting) }
    guard !inst.app.isTerminated, sameProcess(inst.app).isEmpty else { return }
    if inst.ours {
      terminate(inst.app)
      return
    }
    if let frame = inst.restore, let win = inst.window {
      // En-boy kısıtlı pencerede boyut değişimi konumu oynatır (Chess'te 3 px ölçüldü): konum en son.
      axSetSize(win, frame.size)
      axSetPoint(win, frame.origin)
      axSetSize(win, frame.size)
      axSetPoint(win, frame.origin)
    }
    if hide { inst.app.hide() }
  }

  private func activate(_ app: NSRunningApplication) {
    if #available(macOS 14.0, *) {
      NSApp.yieldActivation(to: app)
      _ = app.activate()
    } else {
      _ = app.activate(options: [])
    }
  }

  /// Hedefi bizim pencerenin hemen altına çeker (hedef uygulama etkinleşmez).
  private func raiseBelowUs() {
    guard let win = targetWindow, paused.isEmpty else { return }
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    if NSApp.isActive { window?.orderFront(nil) }
  }

  // MARK: İkinci hesap (ayrı veri klasörlü örnek)

  /// Ayrı veri klasörüyle ikinci örnek: Electron `--user-data-dir` kabul eder. Çerçevenin adı değişebilir
  /// (ChatGPT'de "Codex Framework"): paket arşivi ya da Info.plist'teki ElectronAsarIntegrity de sayılır.
  private static func isElectron(_ url: URL) -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
      || fm.fileExists(atPath: url.appendingPathComponent("Contents/Resources/app.asar").path)
      || Bundle(url: url)?.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil
  }

  private func profilesRoot() -> URL {
    if let profilesOverride { return profilesOverride }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.enes.allai", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
  }

  /// `profiles/<key>`: anahtar tek, güvenli bir klasör adı olmalı.
  private func profileDir(_ key: String) -> URL? {
    guard !key.isEmpty, key.count <= 128, key != ".", key != "..",
          !key.contains("/"), !key.contains("\0") else { return nil }
    return profilesRoot().appendingPathComponent(key, isDirectory: true)
  }

  /// İkinci hesap kartı silindi: klasörü kullanan örnek kapatılır (en çok 5 sn beklenir), klasör silinir.
  private func deleteProfile(_ key: String, done: @escaping () -> Void) {
    guard let dir = profileDir(key) else { return done() }
    close(key)
    let path = dir.path
    let apps = NSWorkspace.shared.runningApplications.filter {
      !$0.isTerminated && Self.userDataDir($0.processIdentifier) == path
    }
    apps.forEach(terminate)
    let root = profilesRoot()
    let deadline = Date().addingTimeInterval(5)
    func finish() {
      let alive = apps.filter { !$0.isTerminated }
      if !alive.isEmpty, Date() < deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { finish() }
        return
      }
      // Electron kapanırken çerezleri yeniden yazar: süreç bitmeden silinmez, bitince silinir.
      if alive.isEmpty {
        Self.removeProfile(dir, root: root)
      } else {
        alive.forEach { pendingDeletes[$0.processIdentifier] = dir }
        var list = UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey) ?? []
        if !list.contains(dir.path) { list.append(dir.path) }
        UserDefaults.standard.set(list, forKey: Self.pendingDeletesKey)
      }
      done()
    }
    finish()
  }

  /// Bekleyen silme: klasör silinir, kalıcı listeden düşer.
  private func removePending(_ dir: URL) {
    Self.removeProfile(dir, root: profilesRoot())
    let list = (UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey) ?? []).filter { $0 != dir.path }
    UserDefaults.standard.set(list, forKey: Self.pendingDeletesKey)
  }

  /// Önceki oturumdan kalan silmeler: klasörü kullanan süreç yoksa şimdi silinir.
  private func removeLeftoverProfiles() {
    for path in UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey) ?? [] {
      let busy = NSWorkspace.shared.runningApplications.contains { !$0.isTerminated && Self.userDataDir($0.processIdentifier) == path }
      if !busy { removePending(URL(fileURLWithPath: path, isDirectory: true)) }
    }
  }

  /// Yalnız kökün doğrudan altındaki gerçek klasör silinir: sembolik bağlantı ya da kök dışına
  /// çıkan yol reddedilir (kökün kendisi de bağlantı üzerinden gelmemeli). `standardizedFileURL`
  /// kullanılmaz: /private önekini atar, realpath atmaz.
  private static func removeProfile(_ dir: URL, root: URL) {
    guard let realRoot = realPath(root), realRoot == root.path,
          (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
          let real = realPath(dir), (real as NSString).deletingLastPathComponent == realRoot else { return }
    try? FileManager.default.removeItem(atPath: real)
  }

  private static func realPath(_ url: URL) -> String? {
    guard let p = realpath(url.path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
  }

  /// Sürecin komut satırındaki `--user-data-dir` değeri (yazıldığı gibi; açılışta `dir.path` verilir); yoksa nil.
  private static func userDataDir(_ pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
    // Düzen: argc (Int32), çalıştırılabilir yolu, NUL dolgusu, argv..., ortam.
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = 4
    while i < size, buf[i] != 0 { i += 1 }
    while i < size, buf[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < argc, i < size {
      let start = i
      while i < size, buf[i] != 0 { i += 1 }
      args.append(String(decoding: buf[start..<i], as: UTF8.self))
      i += 1
    }
    for (n, arg) in args.enumerated() {
      if arg.hasPrefix("--user-data-dir=") { return String(arg.dropFirst("--user-data-dir=".count)) }
      if arg == "--user-data-dir", n + 1 < args.count { return args[n + 1] }
    }
    return nil
  }

  // MARK: Geometri

  private func setHole(_ rect: CGRect) {
    guard let view = window?.contentView, rect.width >= 1, rect.height >= 1 else {
      hasHole = false
      return
    }
    let bounds = view.bounds.size
    insets = NSEdgeInsets(top: rect.minY, left: rect.minX,
                          bottom: bounds.height - rect.maxY, right: bounds.width - rect.maxX)
    hasHole = true
  }

  /// Delik, Cocoa genel koordinatında (birincil ekranın sol altı köken). [frame]: pencere henüz
  /// oraya taşınmadan (sürükleme adımı, setFrame) deliğin nerede olacağı.
  private func holeOnScreen(for frame: NSRect? = nil) -> CGRect? {
    guard hasHole, let window, let view = window.contentView else { return nil }
    var content = window.convertToScreen(view.convert(view.bounds, to: nil))
    if let frame {
      // İçerik görünümü pencere çerçevesine sabit kenar paylarıyla bağlı.
      let now = window.frame
      content = NSRect(x: content.minX - now.minX + frame.minX, y: content.minY - now.minY + frame.minY,
                       width: content.width - now.width + frame.width, height: content.height - now.height + frame.height)
    }
    let width = content.width - insets.left - insets.right
    let height = content.height - insets.top - insets.bottom
    guard width >= 1, height >= 1 else { return nil }
    return CGRect(x: content.minX + insets.left, y: content.minY + insets.bottom, width: width, height: height)
  }

  /// Delik, AX genel koordinatında (birincil ekranın sol üstü köken, y aşağı).
  private func holeAX(for frame: NSRect? = nil) -> CGRect? {
    guard let r = holeOnScreen(for: frame), let primary = NSScreen.screens.first else { return nil }
    return CGRect(x: r.minX.rounded(), y: (primary.frame.maxY - r.maxY).rounded(),
                  width: r.width.rounded(), height: r.height.rounded())
  }

  private func place(force: Bool = false, for frame: NSRect? = nil) {
    guard let win = targetWindow, paused.isEmpty, let want = holeAX(for: frame) else { return }
    if !force, want == lastPlaced { return }
    let resize = force || want.size != lastPlaced?.size
    // Boyut-konum-boyut: ekran kenarına göre kısıtlanan boyut, konumdan sonra düzelir.
    if resize { axSetSize(win, want.size) }
    axSetPoint(win, want.origin)
    if resize {
      axSetSize(win, want.size)
      acceptedSize = axSize(win)
    }
    lastPlaced = want
  }

  /// Pencerenin çerçevesi değişmek üzere (canlı boyutlanma, büyütme): hedef aynı adımda,
  /// bizden önce yeni deliğe oturur.
  func willSetFrame(_ frame: NSRect) {
    if drag == nil { place(for: frame) }
  }

  // MARK: Sürükleme

  /// Yerleşikken pencereyi kendimiz sürükleriz: pencere sunucusu sürüklediğinde hedef, çerçeve
  /// değişimini sonradan görüp geriden gelir. Olaylar Flutter'a da gider; bırakışı görür, jest takılmaz.
  /// Yerleşik değilse false: sistem sürüklemesi (performDrag) kullanılır.
  func beginDrag(_ down: NSEvent) -> Bool {
    guard let window, targetWindow != nil, paused.isEmpty, drag == nil else { return false }
    dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown]) {
      [weak self] event in
      // Yeni basış: bırakış kaçmış demektir (pan başlangıcı geç geldi); sürükleme biter.
      if event.type != .leftMouseDragged {
        self?.endDrag()
      } else if self?.dragLink == nil {
        self?.dragTick()
      }
      return event
    }
    startDrag(grab: window.convertPoint(toScreen: down.locationInWindow)) { NSEvent.mouseLocation }
    return true
  }

  /// Adımlar ekran yenilemesine kilitli (kare başında). Electron hedef, AX ile gelen konumu ekrana
  /// 1, yükte 2 kare sonra verir, bizim pencere bir sonraki karede (ölçüldü): sıralama ya da kare
  /// hizası bu kaymayı her zaman kapatamaz. Bu yüzden sürüklemede delik örtülür, hedef altta taşınır.
  /// [pointer]: imlecin ekran konumu (deneme kancasında programla üretilir).
  private func startDrag(grab: NSPoint, pointer: @escaping () -> NSPoint) {
    guard let window else { return }
    drag = (window.frame.origin, grab, pointer)
    coverOn()
    if #available(macOS 14.0, *), let view = window.contentView {
      let link = view.displayLink(target: self, selector: #selector(dragTick))
      link.add(to: .main, forMode: .common)
      dragLink = link
    }
    // Basış ile Flutter'ın pan başlangıcı arasında imleç biraz yürüdü: hemen yetiş.
    dragTick()
  }

  @objc private func dragTick() {
    guard let drag, let window else { return }
    let p = drag.pointer()
    var frame = window.frame
    // İmleç kesirli noktada olabilir; delik AX'e tam noktayla gider, pencere de tam noktada kalsın.
    frame.origin = NSPoint(x: (drag.origin.x + p.x - drag.grab.x).rounded(), y: (drag.origin.y + p.y - drag.grab.y).rounded())
    // Sistem sürüklemesi gibi: üst kenar, imlecin bulunduğu ekranın menü çubuğunun altına geçemez.
    let mouse = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? window.screen {
      frame.origin.y = min(frame.origin.y, screen.visibleFrame.maxY - frame.height)
    }
    guard frame.origin != window.frame.origin else { return }
    place(for: frame)
    window.setFrameOrigin(frame.origin)
  }

  private func endDrag() {
    if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
    dragMonitor = nil
    if #available(macOS 14.0, *) { (dragLink as? CADisplayLink)?.invalidate() }
    dragLink = nil
    guard drag != nil else { return }
    drag = nil
    uncoverWhenSettled()
    DispatchQueue.main.async { [weak self] in self?.updateThrough() }
  }

  // MARK: Örtü

  /// Deliği örter: Flutter marka zemini + simge çizer (`coverOn` olayı). Ekran kaydı izni varsa hedefin
  /// görüntüsü alınır ve gelince üstüne konur; bizim pencerenin parçası olduğu için onunla aynı karede taşınır.
  private func coverOn() {
    guard targetWindow != nil, hasHole else { return }
    coverGen += 1
    if let pid = target?.processIdentifier, let at = lastPlaced?.origin {
      coverTargetId = Self.windowId(pid: pid, at: at)
    }
    if !covered {
      covered = true
      emit("coverOn", targetKey, target?.bundleIdentifier)
      log("örtü açıldı")
      captureSnapshot()
    }
  }

  /// Hedef son konum ve boyutuna iki ardışık karede oturunca (pencere sunucusunda, AX'in döndürdüğü
  /// istenen değerde değil) örtü kalkar; en çok 0,5 sn beklenir.
  private func uncoverWhenSettled() {
    guard covered else { return }
    let gen = coverGen, start = CACurrentMediaTime()
    var stable = 0
    func check() {
      guard gen == coverGen, covered else { return }
      let want = lastPlaced, at = coverTargetId.flatMap(Self.windowFrame)
      if let want, let at, at.origin == want.origin,
         abs(at.width - (acceptedSize ?? want.size).width) <= 1, abs(at.height - (acceptedSize ?? want.size).height) <= 1 {
        stable += 1
      } else {
        stable = 0
      }
      if stable >= 2 || CACurrentMediaTime() - start > 0.5 {
        log(String(format: "örtü kalktı: %.0f ms, oturdu=%@, hedef=%@ istenen=%@", (CACurrentMediaTime() - start) * 1000,
                   stable >= 2 ? "evet" : "hayır", "\(at.map { NSStringFromRect($0) } ?? "-")", "\(want.map { NSStringFromRect($0) } ?? "-")"))
        uncover()
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { check() }
      }
    }
    check()
  }

  private func uncover() {
    guard covered else { return }
    covered = false
    coverGen += 1
    emit("coverOff", targetKey, target?.bundleIdentifier)
    // Görüntü katmanı Flutter örtüsünün üstünde: önce o kalkar, sonra görüntü (arada zemin görünmez).
    let view = coverView
    coverView = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { view?.removeFromSuperview() }
  }

  /// Örtü açılınca hedefin görüntüsü alınır (yalnız ekran kaydı izni varsa; istem çıkarılmaz).
  /// Geç gelen görüntü yalnız aynı örtüde gösterilir (`coverGen`): eski görüntü yeni sürüklemeye karışmaz.
  /// Hazır görüntü varsa hemen konur; 2 sn'den eskiyse yenisi alınıp yerine geçer.
  private func captureSnapshot() {
    guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(), let id = coverTargetId else { return }
    if let ready, ready.id == id {
      log(String(format: "görüntü hazırdı (%.1f sn önce alınmış)", CACurrentMediaTime() - ready.at))
      showSnapshot(ready.image)
      if CACurrentMediaTime() - ready.at < 2 { return }
    }
    let gen = coverGen, started = CACurrentMediaTime()
    Task { @MainActor [weak self] in
      guard let image = await self?.capture(id) else { return }
      self?.ready = (id, image, CACurrentMediaTime())
      guard let self, self.covered, gen == self.coverGen else { return }
      self.log(String(format: "görüntü alındı: %.1f ms", (CACurrentMediaTime() - started) * 1000))
      self.showSnapshot(image)
    }
  }

  /// İmleç pencerenin üst çubuğunda ya da kenarında (sürükleme/boyutlanma yakın): örtü açılınca
  /// beklemeden konacak görüntü alınır. En çok 2 sn'de bir.
  private func prepareSnapshot() {
    guard #available(macOS 14.0, *), !preparing, !covered, drag == nil, paused.isEmpty,
          let pid = target?.processIdentifier, let at = lastPlaced?.origin else { return }
    if let ready, CACurrentMediaTime() - ready.at < 2 { return }
    guard CGPreflightScreenCaptureAccess(), let id = Self.windowId(pid: pid, at: at) else { return }
    preparing = true
    let started = CACurrentMediaTime()
    Task { @MainActor [weak self] in
      let image = await self?.capture(id)
      guard let self else { return }
      self.preparing = false
      guard let image, self.target?.processIdentifier == pid else { return }
      self.ready = (id, image, CACurrentMediaTime())
      self.log(String(format: "görüntü hazırlandı: %.1f ms", (CACurrentMediaTime() - started) * 1000))
    }
  }

  /// Süzgeç hedef pencere için bir kez kurulur; boyut her seferinde pencere sunucusundan okunur.
  @available(macOS 14.0, *)
  private func capture(_ id: CGWindowID) async -> CGImage? {
    var filter = filterCache?.id == id ? filterCache?.filter as? SCContentFilter : nil
    if filter == nil {
      guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let win = content.windows.first(where: { $0.windowID == id }) else { return nil }
      filter = SCContentFilter(desktopIndependentWindow: win)
      filterCache = (id, filter!)
    }
    guard let filter, let size = Self.windowFrame(id)?.size else { return nil }
    let config = SCStreamConfiguration()
    config.width = Int(size.width * CGFloat(filter.pointPixelScale))
    config.height = Int(size.height * CGFloat(filter.pointPixelScale))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
      if filterCache?.id == id { filterCache = nil }
      return nil
    }
    return image
  }

  private func showSnapshot(_ image: CGImage) {
    guard let window, let view = window.contentView else { return }
    let scale = window.backingScaleFactor
    let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    // Hazır görüntü konmuşsa yenisi yalnız resmi değiştirir.
    if let coverView {
      coverView.image = NSImage(cgImage: image, size: size)
      return
    }
    let imageView = NSImageView(frame: .zero)
    imageView.image = NSImage(cgImage: image, size: size)
    imageView.imageScaling = .scaleNone
    imageView.imageAlignment = .alignTopLeft
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 10
    imageView.layer?.masksToBounds = true
    view.addSubview(imageView)
    coverView = imageView
    layoutCover()
  }

  /// Görüntü deliği kaplar, içeriği sol üste sabit: canlı boyutlanmada büyüyen kısımda altındaki
  /// marka zemini görünür, hedef altta yeniden dizilirken görüntü kaymaz.
  private func layoutCover() {
    guard let coverView, let window, let view = window.contentView, let hole = holeOnScreen() else { return }
    coverView.frame = view.convert(window.convertFromScreen(hole), from: nil)
  }

  /// Hedefin pencere sunucusundaki kimliği (AX konumu ile CG konumu aynı köşe ve eksende).
  private static func windowId(pid: pid_t, at: CGPoint) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return list.first {
      ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && bounds($0)?.origin == at
    }?[kCGWindowNumber as String] as? CGWindowID
  }

  /// Pencere sunucusundaki kayıt (yoksa pencere kapanmıştır).
  private static func windowInfo(_ id: CGWindowID) -> [String: Any]? {
    var raw: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
    guard let ids = CFArrayCreate(nil, &raw, 1, nil) else { return nil }
    return (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first
  }

  /// Pencerenin ekranda göründüğü çerçeve (AX'in döndürdüğü istenen değer değil).
  private static func windowFrame(_ id: CGWindowID) -> CGRect? {
    windowInfo(id).flatMap(bounds)
  }

  private static func bounds(_ info: [String: Any]) -> CGRect? {
    guard let dict = info[kCGWindowBounds as String] else { return nil }
    return CGRect(dictionaryRepresentation: dict as! CFDictionary)
  }

  private func log(_ message: String) {
    // print dosyaya yönlenince tamponda kalır; satır hemen yazılsın.
    if debugLog { FileHandle.standardOutput.write(Data("ALLAI_DOCK \(message)\n".utf8)) }
  }

  /// Yalnız profil/hata ayıklama: gerçek sürüklemeyle aynı yoldan (startDrag) imleci programla
  /// yürütür, 600 px/sn (60 Hz'de 10 px/kare); ardından setFrame ile (canlı boyutlanmanın yolu)
  /// sağ alt köşeden büyütüp küçültür. Örtünün kalkışı ALLAI_DOCK satırlarıyla stdout'a yazılır.
  private func runDragTest() {
    guard targetWindow != nil, drag == nil else { return }
    let segments: [(CGFloat, CGFloat, Int)] = [(10, 0, 15), (-10, 0, 30), (10, 0, 15), (0, -10, 8), (0, 10, 8)]
    var steps: [CGPoint] = [.zero]
    for _ in 0..<2 {
      for (dx, dy, n) in segments {
        for _ in 0..<n { steps.append(CGPoint(x: steps.last!.x + dx, y: steps.last!.y + dy)) }
      }
    }
    log("ekran kaydı izni: \(CGPreflightScreenCaptureAccess())")
    let t0 = CACurrentMediaTime()
    startDrag(grab: .zero) { steps[min(steps.count - 1, Int((CACurrentMediaTime() - t0) * 60))] }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps.count) / 60 + 0.1) { [weak self] in
      self?.endDrag()
      // Canlı boyutlanmanın bildirimleri (willStart/didEndLiveResize) yerine aynı çağrılar elle.
      var n = 0
      let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
        if n == 0 { self?.coverOn() }
        guard let window = self?.window, self?.targetWindow != nil, n < 60 else {
          self?.uncoverWhenSettled()
          return t.invalidate()
        }
        let d: CGFloat = n < 30 ? 1 : -1
        var f = window.frame
        f.size.width += 10 * d
        f.size.height += 6 * d
        f.origin.y -= 6 * d
        window.setFrame(f, display: true)
        n += 1
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { RunLoop.main.add(t, forMode: .common) }
    }
  }

  // MARK: Tıklama geçişi

  /// İmleç delikteyken pencere fareyi yok sayar, olaylar alttaki uygulamaya gider. Yoklama yok:
  /// imleç hareketinde (bizde ya da başka uygulamada) ve bırakışta güncellenir. Arka plandaki
  /// uygulamanın zamanlayıcısı sistemce seyreltildiği için yoklama, hedef etkinken geç kalıyordu.
  private func startTracking() {
    stopTracking()
    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
    if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.updateThrough() }) {
      monitors.append(m)
    }
    if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
      self?.updateThrough()
      return event
    }) {
      monitors.append(m)
    }
    updateThrough()
  }

  private func stopTracking() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  private func updateThrough() {
    guard let window, targetWindow != nil else { return }
    // Düğme basılıyken durum değişmez: sürükleme ortasında olay hedefi kaymasın.
    guard NSEvent.pressedMouseButtons == 0 else { return }
    let mouse = NSEvent.mouseLocation, hole = holeOnScreen()
    let through = paused.isEmpty && (hole?.contains(mouse) ?? false)
    if window.ignoresMouseEvents != through { window.ignoresMouseEvents = through }
    // Üst çubukta ya da kenara 16 nokta yakın: sürükleme/boyutlanma gelebilir.
    if let hole, window.frame.insetBy(dx: -6, dy: -6).contains(mouse), !hole.insetBy(dx: 16, dy: 16).contains(mouse) {
      prepareSnapshot()
    }
  }

  private func addObserver(_ pid: pid_t, _ win: AXUIElement) {
    var created: AXObserver?
    guard AXObserverCreate(pid, axCallback, &created) == .success, let created else { return }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXMovedNotification, kAXResizedNotification,
                 kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
      AXObserverAddNotification(created, win, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    observer = created
  }

  fileprivate func axNotification(_ name: String) {
    switch name {
    case kAXMovedNotification, kAXResizedNotification:
      pinNow()
      scheduleSnap()
    case kAXWindowMiniaturizedNotification:
      let key = targetKey, id = target?.bundleIdentifier
      undock()
      emit("windowLost", key, id)
    case kAXUIElementDestroyedNotification:
      // Uygulama kapanırken de pencere yok olur: yerleştirme hemen durur, olay türü
      // sonlanma bildirimi beklenerek seçilir (Electron kapanışı ~1 sn sürebilir).
      guard let app = target, let key = targetKey else { return }
      if instances[key]?.webWindow == true {
        // Chrome penceresi kapandı (sahip kapattı): kart o pencereydi, Chrome çalışmaya devam eder.
        forget(key)
        undock()
        emit("terminated", key, app.bundleIdentifier)
        return
      }
      undock()
      lostApp = app
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.lostApp === app else { return }
        self.lostApp = nil
        self.emit(app.isTerminated ? "terminated" : "windowLost", key, app.bundleIdentifier)
      }
      lostWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    default:
      break
    }
  }

  /// Yerleşik pencere taşındı ya da boyutlandırıldı (kullanıcı kendi başlığından sürükledi): bırakmayı
  /// beklemeden aynı olayda yerine konur, pencere deliğinden ayrılamaz. Bizim yerleştirmemizin
  /// yankısı (zaten yerinde) ve bizim sürüklememiz/boyutlanmamız sırasında dokunulmaz.
  private func pinNow() {
    guard let win = targetWindow, paused.isEmpty, drag == nil, !(window?.inLiveResize ?? false),
          let want = lastPlaced, let pos = axPoint(win) else { return }
    if abs(pos.x - want.minX) > 1 || abs(pos.y - want.minY) > 1 { axSetPoint(win, want.origin) }
    if let size = axSize(win), let expected = acceptedSize ?? Optional(want.size),
       abs(size.width - expected.width) > 1 || abs(size.height - expected.height) > 1 {
      place(force: true)
    }
  }

  /// Hedef kullanıcı ya da kendisi tarafından taşınırsa sürükleme bitince yerine döner.
  private func scheduleSnap() {
    snapWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.snapBack() }
    snapWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  private func snapBack() {
    guard let win = targetWindow, paused.isEmpty else { return }
    if NSEvent.pressedMouseButtons != 0 { return scheduleSnap() }
    if axBool(win, "AXFullScreen") == true { return }
    guard let want = holeAX(), let pos = axPoint(win), let size = axSize(win) else { return }
    let expected = acceptedSize ?? want.size
    if abs(pos.x - want.minX) > 1 || abs(pos.y - want.minY) > 1
        || abs(size.width - expected.width) > 1 || abs(size.height - expected.height) > 1 {
      place(force: true)
    }
  }

  // MARK: Bizim pencere ve sistem olayları

  private func observe(_ window: NSWindow) {
    let nc = NotificationCenter.default
    func on(_ name: Notification.Name, _ object: AnyObject?, _ block: @escaping () -> Void) {
      tokens.append(nc.addObserver(forName: name, object: object, queue: .main) { _ in block() })
    }
    // Sürüklemede hedefi yalnız sürükleme döngüsü yerleştirir.
    on(NSWindow.didMoveNotification, window) { [weak self] in
      if self?.drag == nil { self?.place() }
      self?.updateThrough()
    }
    on(NSWindow.didResizeNotification, window) { [weak self] in
      if self?.drag == nil { self?.place() }
      self?.layoutCover()
      self?.updateThrough()
    }
    on(NSWindow.willStartLiveResizeNotification, window) { [weak self] in self?.coverOn() }
    on(NSWindow.didEndLiveResizeNotification, window) { [weak self] in self?.uncoverWhenSettled() }
    on(NSWindow.willEnterFullScreenNotification, window) { [weak self] in
      guard let self else { return }
      self.fullScreenBusy = true
      if self.targetWindow != nil {
        self.pause(.fullScreen)
        self.emit("fullscreenUnsupported", self.targetKey, self.target?.bundleIdentifier)
      }
    }
    on(NSWindow.didEnterFullScreenNotification, window) { [weak self] in self?.fullScreenBusy = false }
    on(NSWindow.willExitFullScreenNotification, window) { [weak self] in self?.fullScreenBusy = true }
    on(NSWindow.didExitFullScreenNotification, window) { [weak self] in
      guard let self else { return }
      self.fullScreenBusy = false
      if self.paused.contains(.fullScreen) {
        self.resume(.fullScreen)
        self.emit("docked", self.targetKey, self.target?.bundleIdentifier)
      }
    }
    on(NSWindow.willMiniaturizeNotification, window) { [weak self] in self?.willMiniaturize() }
    on(NSWindow.didMiniaturizeNotification, window) { [weak self] in self?.pause(.miniaturized) }
    on(NSWindow.didDeminiaturizeNotification, window) { [weak self] in self?.resume(.miniaturized) }
    on(NSApplication.didHideNotification, nil) { [weak self] in self?.pause(.appHidden) }
    on(NSApplication.didUnhideNotification, nil) { [weak self] in self?.resume(.appHidden) }
    on(NSApplication.didBecomeActiveNotification, nil) { [weak self] in
      // Etkinleşme anında pencere sunucusu sırayı bitirmemiş olur; hemen yapılan raise
      // hedefi araya giren pencerenin altına koyar (ölçüldü).
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.raiseBelowUs() }
    }
    on(NSApplication.didChangeScreenParametersNotification, nil) { [weak self] in self?.place(force: true) }
    on(NSApplication.willTerminateNotification, nil) { [weak self] in self?.releaseAll() }

    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
      tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] note in
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
          self?.targetSurfaced(app)
          if note.name == NSWorkspace.didActivateApplicationNotification { self?.targetActivated(app) }
        }
      })
    }

    tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self,
            let gone = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      // Kapatılan (close) kartın kaydı silinmiştir: ona olay gitmez.
      let pid = gone.processIdentifier
      self.terminating.remove(pid)
      if let dir = self.pendingDeletes.removeValue(forKey: pid), !self.pendingDeletes.values.contains(dir) {
        self.removePending(dir)
      }
      if self.webObserverPid == pid, let observer = self.webObserver {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.webObserver = nil
        self.webObserverPid = nil
      }
      let keys = self.instances.filter { $0.value.app.processIdentifier == pid }.map(\.key)
      keys.forEach { self.instances[$0] = nil }
      if self.target?.processIdentifier == pid || self.lostApp?.processIdentifier == pid { self.undock() }
      keys.forEach { self.emit("terminated", $0, gone.bundleIdentifier) }
    })
  }

  private func pause(_ reason: Pause) {
    guard targetWindow != nil else { return }
    paused.insert(reason)
    endDrag()
    // Küçültmede görüntü, pencere Dock'a uçarken içerik yerinde kalsın diye açılışta konur; geri
    // gelince yerleşim oturduktan sonra kalkar.
    if reason != .miniaturized { uncover() }
    window?.ignoresMouseEvents = false
    // Küçültme / gizlemede yerleşik pencere ortada asılı kalmasın.
    if reason != .fullScreen { conceal(targetKey.flatMap { instances[$0] }) }
  }

  private func resume(_ reason: Pause) {
    guard targetWindow != nil, paused.remove(reason) != nil, paused.isEmpty else { return }
    if targetKey.flatMap({ instances[$0] })?.webWindow != true { target?.unhide() }
    place(force: true)
    raiseBelowUs()
    updateThrough()
    uncoverWhenSettled()
  }

  /// Küçültmeden önce örtü açılır ve Flutter'ın bunu çizmesi için birkaç kare beklenir; yoksa Dock
  /// animasyonu boş delikle başlar. Sürüklemedeki örtünün aynısı (görüntü + marka zemini).
  func prepareMinimize(_ go: @escaping () -> Void) {
    guard targetWindow != nil, paused.isEmpty, hasHole, drag == nil else { return go() }
    coverOn()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { go() }
  }

  /// Küçültme animasyonu başlamadan: hedefin görüntüsü bizim pencereye konur, hedef gizlenir. Böylece
  /// içerik, pencerenin kendisiyle birlikte Dock'a küçülür (üst çubuk tek başına küçülmez).
  /// Görüntü yoksa (ekran kaydı izni yok) yalnız hedef gizlenir.
  private func willMiniaturize() {
    guard targetWindow != nil, paused.isEmpty, let pid = target?.processIdentifier, let at = lastPlaced?.origin,
          let id = Self.windowId(pid: pid, at: at) else { return }
    endDrag()
    if let ready, ready.id == id, covered == false {
      coverTargetId = id
      covered = true
      coverGen += 1
      showSnapshot(ready.image)
      window?.contentView?.displayIfNeeded()
    }
    pause(.miniaturized)
  }

  /// Hedef uygulama etkinleşti (içeriğine tıklandı) ama AllAI arkada kaldı: AllAI'nin penceresi de, etkinleşmeden,
  /// öne gelir; üst çubuk içerikle birlikte yükselir. Sahibin kendi Chrome pencereleri için
  /// yalnız odaktaki pencere bizimkiyse.
  private func targetActivated(_ app: NSRunningApplication) {
    guard let win = targetWindow, paused.isEmpty, app.processIdentifier == target?.processIdentifier,
          !NSApp.isActive else { return }
    // Etkinleşme anında pencere sunucusu sırayı bitirmemiş olur (bkz. didBecomeActive).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, let window = self.window, self.targetWindow != nil, self.paused.isEmpty,
            !window.isMiniaturized, !NSApp.isActive else { return }
      let ax = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(ax, 0.3)
      guard let focused = axElement(ax, kAXFocusedWindowAttribute), CFEqual(focused, win) else { return }
      window.orderFront(nil)
      AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }
  }

  /// Hedef uygulama Dock'tan seçildi ya da gösterildi, ama AllAI küçültülmüş/gizli: AllAI de geri gelir
  /// (yoksa hedef pencere tek başına, deliksiz ve çerçevesiz ortada açılırdı).
  private func targetSurfaced(_ app: NSRunningApplication) {
    guard targetWindow != nil, !paused.isEmpty, app.processIdentifier == target?.processIdentifier,
          paused.isSubset(of: [.miniaturized, .appHidden]), let window else { return }
    if NSApp.isHidden { NSApp.unhide(nil) }
    if window.isMiniaturized { window.deminiaturize(nil) }
  }
}

// MARK: AX yardımcıları

private func webAxCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString,
                           _ refcon: UnsafeMutableRawPointer?) {
  guard let refcon else { return }
  Unmanaged<AppDockController>.fromOpaque(refcon).takeUnretainedValue().webWindowDestroyed(element)
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
  guard let refcon else { return }
  Unmanaged<AppDockController>.fromOpaque(refcon).takeUnretainedValue().axNotification(name as String)
}

private func launchAxCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString,
                              _ refcon: UnsafeMutableRawPointer?) {
  guard let refcon else { return }
  Unmanaged<AppDockController>.fromOpaque(refcon).takeUnretainedValue().launchWindowCreated(element)
}

/// Ana pencere (standartsa), yoksa küçültülmemiş en büyük standart pencere.
private func findStandardWindow(_ pid: pid_t) -> AXUIElement? {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 0.5)
  let windows = axElements(app, kAXWindowsAttribute).filter {
    axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
  }
  if let main = axElement(app, kAXMainWindowAttribute), axBool(main, kAXMinimizedAttribute) != true,
     windows.contains(where: { CFEqual($0, main) }) {
    return main
  }
  func area(_ w: AXUIElement) -> CGFloat { axSize(w).map { $0.width * $0.height } ?? 0 }
  let visible = windows.filter { axBool($0, kAXMinimizedAttribute) != true }
  return visible.max { area($0) < area($1) } ?? windows.first
}

private func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
  return value
}

private func axString(_ el: AXUIElement, _ attr: String) -> String? {
  axValue(el, attr) as? String
}

private func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
  axValue(el, attr) as? Bool
}

private func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
  guard let value = axValue(el, attr), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return unsafeBitCast(value, to: AXUIElement.self)
}

/// Uygulamanın pencereleri (önden arkaya); AX hatasında nil: boş liste sayılmaz.
private func axWindows(_ app: AXUIElement) -> [AXUIElement]? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
        let list = value as? [AnyObject] else { return nil }
  return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
}

private func axElements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
  guard let list = axValue(el, attr) as? [AnyObject] else { return [] }
  return list.compactMap {
    CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
  }
}

private func axPoint(_ el: AXUIElement) -> CGPoint? {
  guard let value = axValue(el, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  var point = CGPoint.zero
  return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
}

private func axSize(_ el: AXUIElement) -> CGSize? {
  guard let value = axValue(el, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  var size = CGSize.zero
  return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) ? size : nil
}

private func axFrame(_ el: AXUIElement) -> CGRect? {
  guard let p = axPoint(el), let s = axSize(el) else { return nil }
  return CGRect(origin: p, size: s)
}

private func axSetPoint(_ el: AXUIElement, _ point: CGPoint) {
  var p = point
  if let value = AXValueCreate(.cgPoint, &p) {
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, value)
  }
}

private func axSetSize(_ el: AXUIElement, _ size: CGSize) {
  var s = size
  if let value = AXValueCreate(.cgSize, &s) {
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, value)
  }
}

private func axSetBool(_ el: AXUIElement, _ attr: String, _ flag: Bool) {
  AXUIElementSetAttributeValue(el, attr as CFString, (flag ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
}
