import 'dart:io';

import 'package:flutter/services.dart';
import 'package:node_core/node_core.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

/// macOS 系统控制：全屏（window_manager）+ 重启应用（重新拉起 bundle）
/// + 重启系统/睡眠（osascript / pmset，系统重启需一次性授权确认）。
class MacSystemControl implements SystemControl {
  String? _bundlePath() {
    final exe = Platform.resolvedExecutable; // …/omniplay.app/Contents/MacOS/omniplay
    final macosDir = File(exe).parent.path;
    if (!macosDir.contains('/Contents/MacOS')) return null;
    return p.normalize(p.join(macosDir, '..', '..'));
  }

  @override
  Future<bool> toggleFullscreen() async {
    final next = !(await windowManager.isFullScreen());
    await windowManager.setFullScreen(next);
    return next;
  }

  @override
  Future<void> restartApp() async {
    final bundle = _bundlePath();
    if (bundle != null && Directory(bundle).existsSync()) {
      await Process.start('open', ['-n', bundle]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    exit(0);
  }

  @override
  Future<void> rebootSystem() async {
    final result = await Process.run('osascript',
        ['-e', 'tell application "System Events" to restart']);
    if (result.exitCode != 0) {
      throw StateError('重启失败（需在系统设置中授权"自动化/辅助功能"）：${result.stderr}');
    }
  }

  @override
  Future<void> sleepSystem() async {
    await Process.run('pmset', ['sleepnow']);
  }
}

/// macOS 键鼠控制（TinyPlay 式电脑控制）：MethodChannel → Swift CGEvent。
/// 首次使用需在"系统设置 → 隐私与安全性 → 辅助功能"中授权本应用。
class MacInputController implements InputController {
  static const _channel = MethodChannel('app.omniplay/native');

  @override
  bool get isSupported => true;

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException {
      // 未授权辅助功能等情况：静默忽略（事件丢失，不中断会话）。
    }
  }

  @override
  Future<void> mouseMove({required double dx, required double dy}) =>
      _invoke('mouseMove', {'dx': dx, 'dy': dy});

  @override
  Future<void> mouseClick({String button = 'left', bool doubleClick = false}) =>
      _invoke('mouseClick', {'button': button, 'doubleClick': doubleClick});

  @override
  Future<void> mouseScroll({required double dx, required double dy}) =>
      _invoke('mouseScroll', {'dx': dx, 'dy': dy});

  @override
  Future<void> keyPress(String key) => _invoke('keyPress', {'key': key});

  @override
  Future<void> keyDown(String key) => _invoke('keyDown', {'key': key});

  @override
  Future<void> keyUp(String key) => _invoke('keyUp', {'key': key});

  @override
  Future<void> inputText(String text) => _invoke('inputText', {'text': text});
}

/// Android 系统控制：无窗口全屏/系统重启权限，仅支持应用重启。
class AndroidSystemControl implements SystemControl {
  @override
  Future<bool> toggleFullscreen() async => false;

  @override
  Future<void> restartApp() async {
    exit(0); // 进程退出；配合前台服务与用户手动重开。
  }

  @override
  Future<void> rebootSystem() async {
    throw UnsupportedError('移动端无系统重启权限');
  }

  @override
  Future<void> sleepSystem() async {
    throw UnsupportedError('移动端不支持系统睡眠');
  }
}
