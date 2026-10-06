/// 系统级控制能力（按平台注入，node_core 保持纯 Dart）。
///
/// - [SystemControl]：全屏/重启应用/重启系统/睡眠（桌面节点全支持；
///   Android 支持应用重启，系统重启无权限不做）。
/// - [InputController]：仿真触控板与键鼠（TinyPlay 式电脑控制，macOS 经
///   CGEvent 实现，需要"辅助功能"权限；移动端节点不支持）。
/// - [WebPresenter]：在线网页承载（优酷/爱奇艺/腾讯等，桌面节点内置
///   WebView 全屏播放；控制端用键鼠/触控板操作，R2 尽力而为）。
abstract class SystemControl {
  /// 切换全屏，返回切换后的状态。
  Future<bool> toggleFullscreen();

  /// 重启节点应用（macOS：重新拉起 bundle 后退出进程）。
  Future<void> restartApp();

  /// 重启宿主系统（macOS 走 AppleScript，需要授权确认）。
  Future<void> rebootSystem();

  /// 让宿主系统睡眠。
  Future<void> sleepSystem();
}

abstract class InputController {
  bool get isSupported;

  Future<void> mouseMove({required double dx, required double dy});

  Future<void> mouseClick({String button = 'left', bool doubleClick = false});

  Future<void> mouseScroll({required double dx, required double dy});

  /// 命名按键：up/down/left/right/enter/esc/space/f/p/m/volumeUp/volumeDown…
  Future<void> keyPress(String key);

  /// 按下不抬起（手柄摇杆/方向键按住语义）。
  Future<void> keyDown(String key) async {}

  /// 抬起（与 keyDown 配对）。
  Future<void> keyUp(String key) async {}

  /// 直接键入文本（CGEvent Unicode，中文尽力而为）。
  Future<void> inputText(String text);
}

abstract class WebPresenter {
  bool get isSupported;

  Future<void> open(String url, {bool maximized = false, String? title});

  Future<void> close();
}
