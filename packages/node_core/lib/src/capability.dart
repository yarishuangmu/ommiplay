import 'package:node_protocol/src/envelope.dart';

/// 节点能力（正交模块）：每个能力自声明拥有的消息类型，核心路由按注册表分发，
/// 新能力（手柄/模拟器/图书馆…）零改动接入（见 docs/capabilities.md）。
abstract class NodeCapability {
  /// 能力 id（'gamepad' / 'web' / 'pointer_input' …）。
  String get id;

  /// 本能力拥有的完整消息类型集合（如 {'input.gamepad'}）。
  Set<String> get handledTypes;

  /// 平台/角色裁剪：不支持时核心路由直接回 input-unsupported 类错误。
  bool get supported;

  /// 处理消息。返回 true=已消费；false=能力拒绝（回 unknown-command）。
  Future<bool> handle(Msg msg);

  /// 能力状态快照（hello/调试用）。
  Map<String, Object?> status() => {'id': id, 'supported': supported};
}

/// 核心路由的能力注册表。
class CapabilityRegistry {
  final Map<String, NodeCapability> _byType = {};
  final List<NodeCapability> _capabilities = [];

  List<NodeCapability> get all => List.unmodifiable(_capabilities);

  void register(NodeCapability capability) {
    _capabilities.removeWhere((c) => c.id == capability.id);
    _capabilities.add(capability);
    for (final type in capability.handledTypes) {
      _byType[type] = capability;
    }
  }

  void registerAll(Iterable<NodeCapability> capabilities) {
    for (final capability in capabilities) {
      register(capability);
    }
  }

  NodeCapability? findByType(String type) => _byType[type];

  List<Map<String, Object?>> statusList() =>
      _capabilities.map((c) => c.status()).toList();
}
