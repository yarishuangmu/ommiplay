import 'package:node_core/node_core.dart';

/// macOS 手柄桥：KeyboardMappedGamepadBridge 的薄封装（CGEvent 键鼠投递，
/// 需辅助功能授权）。真·虚拟 HID 手柄（DriverKit）未来实现 GamepadBridge 替换。
class KeyboardGamepadBridge extends KeyboardMappedGamepadBridge {
  KeyboardGamepadBridge(super.input);
}
