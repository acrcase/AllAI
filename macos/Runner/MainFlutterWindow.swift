import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appDock: AppDockController?
  private var windowChannel: WindowChannel?
  private var goMenu: GoMenu?
  private var keychainChannel: KeychainChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Flutter'ın saydam bıraktığı delikte arkadaki (yerleşik) pencere görünür.
    flutterViewController.backgroundColor = .clear
    // AllAI etkin değilken de (yerleşik uygulama odaktayken) üzerine gelme canlansın.
    flutterViewController.mouseTrackingMode = .always
    contentViewController = flutterViewController

    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isOpaque = false
    backgroundColor = .clear
    // Sistemin durum geri yüklemesi eski çerçeveyi dayatmasın: her açılış 1280×820 ortalı.
    isRestorable = false
    contentMinSize = NSSize(width: 1000, height: 680)
    setContentSize(NSSize(width: 1280, height: 820))
    center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    appDock = AppDockController(window: self, messenger: messenger)
    windowChannel = WindowChannel(window: self, messenger: messenger, dock: appDock)
    goMenu = GoMenu(messenger: messenger)
    keychainChannel = KeychainChannel(messenger: messenger)

    super.awakeFromNib()
  }

  /// Küçültmeden önce yerleşik içeriğin örtüsü çizilir (bkz. AppDockController.prepareMinimize).
  override func miniaturize(_ sender: Any?) {
    guard let appDock else { return super.miniaturize(sender) }
    appDock.prepareMinimize { super.miniaturize(sender) }
  }

  /// Canlı boyutlanma ve büyütmede yerleşik pencere, bizim çerçeve değişmeden yeni deliğe oturur.
  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    appDock?.willSetFrame(frameRect)
    super.setFrame(frameRect, display: flag)
  }
}
