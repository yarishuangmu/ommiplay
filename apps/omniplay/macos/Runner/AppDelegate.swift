import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var nativeChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "app.omniplay/native",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "setKeepAwake":
          // macOS 用 caffeinate 子进程保活，这里无需处理。
          result(nil)
        case "mouseMove":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postMouseMove(
            dx: args["dx"] as? Double ?? 0,
            dy: args["dy"] as? Double ?? 0)
          result(nil)
        case "mouseClick":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postMouseClick(
            button: args["button"] as? String ?? "left",
            doubleClick: args["doubleClick"] as? Bool ?? false)
          result(nil)
        case "mouseScroll":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postScroll(
            dx: args["dx"] as? Double ?? 0,
            dy: args["dy"] as? Double ?? 0)
          result(nil)
        case "keyPress":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postKey(args["key"] as? String ?? "")
          result(nil)
        case "keyDown":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postKey(args["key"] as? String ?? "", keyDown: true)
          result(nil)
        case "keyUp":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postKey(args["key"] as? String ?? "", keyDown: false)
          result(nil)
        case "inputText":
          let args = call.arguments as? [String: Any] ?? [:]
          AppDelegate.postText(args["text"] as? String ?? "")
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      nativeChannel = channel
    }
    super.applicationDidFinishLaunching(notification)
  }

  // MARK: - CGEvent 键鼠控制（需要"辅助功能"授权）

  private static func currentMousePoint() -> CGPoint {
    let mouse = NSEvent.mouseLocation // 左下原点
    let screenHeight = NSScreen.main?.frame.height ?? 800
    return CGPoint(x: mouse.x, y: screenHeight - mouse.y) // 转为左上原点
  }

  private static func postMouseMove(dx: Double, dy: Double) {
    let current = currentMousePoint()
    let next = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
    if let event = CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved,
      mouseCursorPosition: next, mouseButton: .left) {
      event.post(tap: .cghidEventTap)
    }
  }

  private static func postMouseClick(button: String, doubleClick: Bool) {
    let point = currentMousePoint()
    let isRight = button == "right"
    let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
    let mouseButton: CGMouseButton = isRight ? .right : .left
    let clicks = doubleClick ? 2 : 1
    for index in 1...clicks {
      if let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                            mouseCursorPosition: point, mouseButton: mouseButton) {
        down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
        down.post(tap: .cghidEventTap)
      }
      if let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                          mouseCursorPosition: point, mouseButton: mouseButton) {
        up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
        up.post(tap: .cghidEventTap)
      }
      usleep(60_000)
    }
  }

  private static func postScroll(dx: Double, dy: Double) {
    if let event = CGEvent(
      mouseEventSource: nil, mouseType: .scrollWheel,
      mouseCursorPosition: currentMousePoint(), mouseButton: .left) {
      // 滚轮正值向上；触控板向下滑 = 内容向上 = 负 delta。
      event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(-dy))
      event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(-dx))
      event.post(tap: .cghidEventTap)
    }
  }

  // 虚拟键码（ANSI 布局）
  private static let keycodes: [String: Int32] = [
    "up": 126, "down": 125, "left": 123, "right": 124,
    "enter": 36, "esc": 53, "space": 49, "tab": 48,
    "f": 3, "s": 1, "v": 9, "m": 46, "p": 35,
    "volumeUp": 72, "volumeDown": 73, "mute": 74,
    "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
  ]

  private static func postKey(_ key: String, keyDown: Bool) {
    guard let code = keycodes[key.lowercased()] else { return }
    if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: keyDown) {
      event.post(tap: .cghidEventTap)
    }
  }

  private static func postKey(_ key: String) {
    postKey(key, keyDown: true)
    usleep(20_000)
    postKey(key, keyDown: false)
  }

  private static func postText(_ text: String) {
    for char in text {
      var utf16Units = Array(String(char).utf16)
      guard utf16Units.count > 0 else { continue }
      if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
        down.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
        down.post(tap: .cghidEventTap)
      }
      if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
        up.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
        up.post(tap: .cghidEventTap)
      }
      usleep(15_000)
    }
  }
}
