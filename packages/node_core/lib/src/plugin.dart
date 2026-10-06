import 'dart:async';

import 'package:node_core/src/capability.dart';

/// 插件 manifest（plugin.yaml 字段一一对应）。详见 docs/plugin-dev.md。
class PluginManifest {
  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.minNodeVersion = 0,
    this.author = '',
    this.description = '',
    this.dependencies = const {},
  });

  final String id;
  final String name;
  final String version;
  final int minNodeVersion;
  final String author;
  final String description;
  final Map<String, String> dependencies;

  Map<String, Object?> toYaml() => {
        'id': id,
        'name': name,
        'version': version,
        'minNodeVersion': minNodeVersion,
        if (author.isNotEmpty) 'author': author,
        if (description.isNotEmpty) 'description': description,
        if (dependencies.isNotEmpty) 'dependencies': dependencies,
      };

  static PluginManifest fromYaml(Map<String, Object?> yaml) {
    return PluginManifest(
      id: yaml['id'] as String,
      name: yaml['name'] as String,
      version: yaml['version'] as String,
      minNodeVersion: yaml['minNodeVersion'] as int? ?? 0,
      author: yaml['author'] as String? ?? '',
      description: yaml['description'] as String? ?? '',
      dependencies: (yaml['dependencies'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ?? const {},
    );
  }
}

/// 插件上下文（沙箱）：节点能力注册表 + 插件私有存储 + 消息总线。
class PluginContext {
  PluginContext({
    required this.pluginId,
    required this.registry,
    required this.pluginDir,
    required this.broadcast,
  });

  /// 插件 id（如 'com.omniplay.scripts.user'）。
  final String pluginId;

  /// 节点能力注册表（plugin.register(ctx) 时注册；卸载时自动撤销）。
  final CapabilityRegistry registry;

  /// 插件沙箱根目录（~/.omniplay/node/plugins/<id>/），含 db.sqlite 与 user_files/。
  final String pluginDir;

  /// 节点消息广播（订阅后可在控制端看到日志/事件）。
  final void Function(String event, Map<String, Object?> data) broadcast;
}

/// 插件：每个插件一个实例；activate 注册能力，deactivate 自动撤销。
abstract class OmniPlayPlugin {
  PluginManifest get manifest;

  /// 沙箱中加载；throw 表示加载失败，Manager 会记录并跳过。
  FutureOr<void> onLoad(PluginContext context);

  /// 卸载前（资源释放；Manager 已自动撤销该插件注册的所有 Capability）。
  FutureOr<void> onUnload() async {}
}