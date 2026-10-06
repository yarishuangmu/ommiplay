import 'dart:async';

import 'package:node_protocol/src/envelope.dart';

import 'capability.dart';
import 'system_control.dart';

/// 手柄仿真桥（平台注入）：把抽象手柄事件投递为宿主输入。
/// - [KeyboardMappedGamepadBridge]：映射为键盘/鼠标（CGEvent），模拟器与
///   支持键位的 PC 游戏开箱即用（路线 A）；
/// - 真·虚拟 HID 手柄（DriverKit，路线 B）未来实现同一接口替换，协议不变。
abstract class GamepadBridge {
  bool get isSupported;

  Future<void> button(String button, bool pressed);

  Future<void> axis(String stick, double dx, double dy);

  Future<void> reset();
}

/// 手柄映射 Profile：映射方案即数据（纯 Dart，可单测）。
class GamepadProfile {
  const GamepadProfile({
    required this.name,
    required this.buttons,
    this.leftStickKeys = const ['up', 'down', 'left', 'right'],
    this.rightStickAsMouse = true,
    this.deadzone = 0.35,
  });

  /// snes：RetroArch 类模拟器键盘默认布局（方向键移动 + x/z/s/a 按键）。
  static const GamepadProfile snes = GamepadProfile(
    name: 'snes',
    buttons: {
      'a': 'x',
      'b': 'z',
      'x': 's',
      'y': 'a',
      'l1': 'q',
      'r1': 'w',
      'l2': '1',
      'r2': '2',
      'start': 'enter',
      'select': 'esc',
      'dpad_up': 'up',
      'dpad_down': 'down',
      'dpad_left': 'left',
      'dpad_right': 'right',
    },
  );

  /// wasd：通用 PC 游戏（左摇杆=WASD、A=空格、右摇杆=鼠标视角）。
  static const GamepadProfile wasd = GamepadProfile(
    name: 'wasd',
    buttons: {
      'a': 'space',
      'b': 'b',
      'x': 'r',
      'y': 'y',
      'l1': 'q',
      'r1': 'e',
      'l2': '1',
      'r2': '2',
      'start': 'esc',
      'select': 'tab',
      'dpad_up': 'up',
      'dpad_down': 'down',
      'dpad_left': 'left',
      'dpad_right': 'right',
    },
    leftStickKeys: ['w', 's', 'a', 'd'],
  );

  final String name;

  /// 手柄按键 → 宿主按键名。
  final Map<String, String> buttons;

  /// 左摇杆映射的四个方向键：[上, 下, 左, 右]（snes=方向键，wasd=WASD）。
  final List<String> leftStickKeys;

  /// 右摇杆是否作为鼠标视角（true=mouseMove；false=忽略）。
  final bool rightStickAsMouse;

  /// 摇杆死区（归一化 0-1）。
  final double deadzone;
}

/// 路线 A：把手柄事件映射为键鼠事件。维护按住状态——
/// 摇杆只报位置，桥负责在越界/回中时按下/抬起对应方向键。
class KeyboardMappedGamepadBridge implements GamepadBridge {
  KeyboardMappedGamepadBridge(this._input, {GamepadProfile profile = GamepadProfile.snes})
      : _profile = profile;

  final InputController _input;
  GamepadProfile _profile;

  GamepadProfile get profile => _profile;

  /// 切换映射方案：先抬起旧方案按住的键，避免悬挂按键。
  Future<void> setProfile(GamepadProfile value) async {
    await reset();
    _profile = value;
  }

  final Set<String> _heldKeys = {};

  @override
  bool get isSupported => _input.isSupported;

  @override
  Future<void> button(String button, bool pressed) async {
    final key = _profile.buttons[button];
    if (key == null) return;
    if (pressed) {
      await _input.keyDown(key);
      _heldKeys.add(key);
    } else {
      await _input.keyUp(key);
      _heldKeys.remove(key);
    }
  }

  @override
  Future<void> axis(String stick, double dx, double dy) async {
    if (stick == 'right') {
      if (_profile.rightStickAsMouse && (dx.abs() > 0.001 || dy.abs() > 0.001)) {
        await _input.mouseMove(dx: dx * 18, dy: dy * 18);
      }
      return;
    }
    // 左摇杆 → 四方向按住状态。
    final keys = _profile.leftStickKeys; // [上, 下, 左, 右]
    final active = <String>{
      if (dy < -_profile.deadzone) keys[0],
      if (dy > _profile.deadzone) keys[1],
      if (dx < -_profile.deadzone) keys[2],
      if (dx > _profile.deadzone) keys[3],
    };
    // 先抬旧键再按新键：避免换向瞬间方向键双重按住。
    for (final key in _heldKeys.intersection(keys.toSet()).difference(active)) {
      await _input.keyUp(key);
      _heldKeys.remove(key);
    }
    for (final key in active.difference(_heldKeys)) {
      await _input.keyDown(key);
      _heldKeys.add(key);
    }
  }

  @override
  Future<void> reset() async {
    for (final key in List.of(_heldKeys)) {
      await _input.keyUp(key);
      _heldKeys.remove(key);
    }
  }
}

/// 手柄能力：拥有 `input.gamepad` 消息族。
/// payload: `{op:'button', button, pressed}` | `{op:'axis', stick, dx, dy}`
///         | `{op:'profile', name}` | `{op:'reset'}`
class GamepadCapability implements NodeCapability {
  GamepadCapability(this._bridge);

  final GamepadBridge _bridge;

  @override
  String get id => 'gamepad';

  @override
  Set<String> get handledTypes => const {'input.gamepad'};

  @override
  bool get supported => _bridge.isSupported;

  @override
  Future<bool> handle(Msg msg) async {
    switch (msg.pOrNull<String>('op')) {
      case 'button':
        await _bridge.button(msg.p<String>('button'), msg.p<bool>('pressed'));
        return true;
      case 'axis':
        await _bridge.axis(
          msg.pOrNull<String>('stick') ?? 'left',
          (msg.payload['dx'] as num?)?.toDouble() ?? 0,
          (msg.payload['dy'] as num?)?.toDouble() ?? 0,
        );
        return true;
      case 'reset':
        await _bridge.reset();
        return true;
      case 'profile':
        final name = msg.pOrNull<String>('name') ?? 'snes';
        if (_bridge is KeyboardMappedGamepadBridge) {
          await _bridge.setProfile(name == 'wasd' ? GamepadProfile.wasd : GamepadProfile.snes);
        }
        return true;
      default:
        return false;
    }
  }

  @override
  Map<String, Object?> status() =>
      {'id': id, 'supported': supported, 'kind': 'keyboard_mapped'};
}
