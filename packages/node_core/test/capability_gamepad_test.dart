import 'dart:async';

import 'package:node_core/node_core.dart';
import 'package:test/test.dart';

/// 记录型假 InputController：手柄映射测试用。
class RecordingInput implements InputController {
  final List<String> log = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> mouseMove({required double dx, required double dy}) async =>
      log.add('move($dx,$dy)');

  @override
  Future<void> mouseClick({String button = 'left', bool doubleClick = false}) async =>
      log.add('click($button)');

  @override
  Future<void> mouseScroll({required double dx, required double dy}) async =>
      log.add('scroll($dx,$dy)');

  @override
  Future<void> keyPress(String key) async => log.add('press($key)');

  @override
  Future<void> keyDown(String key) async => log.add('down($key)');

  @override
  Future<void> keyUp(String key) async => log.add('up($key)');

  @override
  Future<void> inputText(String text) async => log.add('text($text)');
}

class _NoopCapability implements NodeCapability {
  @override
  String get id => 'noop';

  @override
  Set<String> get handledTypes => {'noop.test'};

  @override
  bool supported = true;

  int handled = 0;

  @override
  Future<bool> handle(Msg msg) async {
    handled++;
    return true;
  }

  @override
  Map<String, Object?> status() => {'id': id};
}

Msg _gamepad(String op, Map<String, Object?> extra) => Msg(
      type: MsgTypes.inputGamepad,
      id: 't',
      ts: '1.0.n',
      from: 'c',
      payload: {'op': op, ...extra},
    );

void main() {
  group('CapabilityRegistry', () {
    test('按消息类型分发；未注册类型查不到', () {
      final registry = CapabilityRegistry();
      final noop = _NoopCapability();
      registry.register(noop);

      expect(registry.findByType('noop.test'), same(noop));
      expect(registry.findByType('other.test'), isNull);
      expect(registry.all.single.id, 'noop');
    });

    test('重复注册同 id 能力会替换且类型不叠加', () {
      final registry = CapabilityRegistry();
      registry.register(_NoopCapability());
      registry.register(_NoopCapability());
      expect(registry.all.length, 1);
    });
  });

  group('KeyboardMappedGamepadBridge（snes Profile）', () {
    late RecordingInput input;
    late KeyboardMappedGamepadBridge bridge;

    setUp(() {
      input = RecordingInput();
      bridge = KeyboardMappedGamepadBridge(input);
    });

    test('按钮按下/抬起映射为目标键的 down/up', () async {
      await bridge.button('a', true);
      await bridge.button('a', false);
      await bridge.button('start', true);
      expect(input.log, ['down(x)', 'up(x)', 'down(enter)']);
    });

    test('左摇杆越死区按住方向键、回中抬起（状态由桥维护）', () async {
      await bridge.axis('left', 0, -1); // 上，按住 up
      expect(input.log, ['down(up)']);
      await bridge.axis('left', 0, -1); // 持续上报同方向：无重复按键
      expect(input.log, ['down(up)']);
      await bridge.axis('left', 0, 0.9); // 从上直接划到下：up 抬起、down 按下
      expect(input.log, ['down(up)', 'up(up)', 'down(down)']);
      await bridge.axis('left', 0, 0); // 回中：全部抬起
      expect(input.log, ['down(up)', 'up(up)', 'down(down)', 'up(down)']);
    });

    test('死区内不触发', () async {
      await bridge.axis('left', 0.2, -0.2);
      expect(input.log, isEmpty);
    });

    test('右摇杆作为鼠标视角（按位移比例）', () async {
      await bridge.axis('right', 0.5, -0.25);
      expect(input.log, ['move(9.0,-4.5)']);
    });

    test('reset 抬起所有按住键', () async {
      await bridge.axis('left', -1, 0); // 按住 left
      expect(input.log, ['down(left)']);
      await bridge.reset();
      expect(input.log, ['down(left)', 'up(left)']);
    });

    test('profile 切换（snes ↔ wasd）后按钮映射随之改变', () async {
      await bridge.button('a', true);
      expect(input.log, ['down(x)']);
      await bridge.setProfile(GamepadProfile.wasd); // reset 抬起按住的 x
      await bridge.button('a', true);
      expect(input.log, ['down(x)', 'up(x)', 'down(space)']);
    });
  });

  group('GamepadCapability', () {
    test('supported 跟随桥；op 分发正确', () async {
      final input = RecordingInput();
      final bridge = KeyboardMappedGamepadBridge(input);
      final capability = GamepadCapability(bridge);

      expect(capability.supported, isTrue);
      expect(capability.handledTypes, {'input.gamepad'});

      expect(await capability.handle(_gamepad('button', {'button': 'b', 'pressed': true})), isTrue);
      expect(input.log, ['down(z)']);

      expect(await capability.handle(_gamepad('axis', {'stick': 'left', 'dx': 0, 'dy': 1})), isTrue);
      expect(input.log, ['down(z)', 'down(down)']);

      expect(await capability.handle(_gamepad('profile', {'name': 'wasd'})), isTrue);
      expect(await capability.handle(_gamepad('reset', {})), isTrue);
      // 重置后 wasd 的 down(s) 被抬起
      expect(input.log.last, 'up(down)');

      expect(await capability.handle(_gamepad('unknown-op', {})), isFalse);
    });
  });
}
