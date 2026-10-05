import 'dart:io';

import 'package:flutter/services.dart';

/// 播放期 keep-awake（需求 1.5 节 M0 交付项）。
/// - macOS：托管 `caffeinate -d -i -s` 子进程（应用运行期间阻止睡眠）。
/// - Android：经 MethodChannel 调 MainActivity 的 FLAG_KEEP_SCREEN_ON。
class KeepAwake {
  static const _channel = MethodChannel('app.omniplay/native');

  Process? _caffeinate;

  /// macOS 在应用启动时调用；Android 走 [setPlaybackActive]。
  Future<void> start() async {
    if (!Platform.isMacOS) return;
    try {
      _caffeinate = await Process.start('caffeinate', ['-d', '-i', '-s']);
    } on ProcessException {
      // caffeinate 不可用时静默降级（不影响功能）。
    }
  }

  /// Android：启动节点前台服务（M0-β 保活）。
  Future<void> startNodeService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startNodeService');
    } on PlatformException {
      // 忽略。
    }
  }

  /// Android：播放状态变化时调用。
  Future<void> setPlaybackActive(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setKeepAwake', active);
    } on PlatformException {
      // 忽略。
    }
  }

  Future<void> dispose() async {
    _caffeinate?.kill();
    _caffeinate = null;
  }
}
