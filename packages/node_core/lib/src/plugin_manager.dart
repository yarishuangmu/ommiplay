import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '_yaml_plugin.dart';
import 'capability.dart';
import 'plugin.dart';

/// 插件运行时（节点内置）：扫描插件目录、加载/卸载插件，撤销能力注册。
///
/// 插件目录约定（沙箱）：
///   ~/.omniplay/node/plugins/<plugin-id>/
///   ├── plugin.yaml      # manifest
///   └── db.sqlite        # 插件私有存储（首次加载时建表）
class PluginManager {
  PluginManager({
    required this.pluginsDir,
    required this.registry,
    required this.broadcast,
  });

  final String pluginsDir;
  final CapabilityRegistry registry;
  final void Function(String event, Map<String, Object?> data) broadcast;

  final Map<String, _Loaded> _loaded = {};
  final Map<String, OmniPlayPlugin> _builtins = {};

  Iterable<PluginManifest> get manifests => _loaded.values.map((l) => l.manifest);

  /// Node 启动时把已实现的内置插件实例注册进来（路由层在
  /// `scanAndLoad` 时用 `registerBuiltIn` 提供）。
  void registerBuiltIn(OmniPlayPlugin plugin) {
    _builtins[plugin.manifest.id] = plugin;
  }

  /// 启动时扫描并加载全部插件。
  Future<List<String>> scanAndLoad() async {
    final errors = <String>[];
    final dir = Directory(pluginsDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      return errors;
    }
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      try {
        await load(entry.path);
      } on Object catch (e) {
        errors.add('${entry.path}: $e');
      }
    }
    return errors;
  }

  /// 加载单个插件（manifest 必须位于 <dir>/plugin.yaml）。
  Future<void> load(String dirPath) async {
    final manifestFile = File(p.join(dirPath, 'plugin.yaml'));
    if (!manifestFile.existsSync()) return;
    final yaml = parseSimpleYaml(await manifestFile.readAsString());
    final manifest = PluginManifest.fromYaml(yaml);
    if (_loaded.containsKey(manifest.id)) return; // 幂等

    // 能力注册前快照：用于卸载时精准撤销该插件注入的能力。
    final preTypes = <String>{};
    for (final c in registry.all) {
      preTypes.add(c.id);
      preTypes.addAll(c.handledTypes);
    }

    final ctx = PluginContext(
      pluginId: manifest.id,
      registry: registry,
      pluginDir: dirPath,
      broadcast: (event, data) => broadcast('plugin.${manifest.id}.$event', data),
    );

    final plugin = _builtins[manifest.id];
    if (plugin == null) {
      throw StateError('插件 ${manifest.id} 找不到实现；请在 registerBuiltIn 提供或升级为动态加载');
    }
    await plugin.onLoad(ctx);

    final postTypes = <String>{};
    for (final c in registry.all) {
      postTypes.add(c.id);
      postTypes.addAll(c.handledTypes);
    }
    final added = postTypes.difference(preTypes);
    final loaded = postTypes.difference(added).toSet();

    _loaded[manifest.id] = _Loaded(
      manifest: manifest,
      plugin: plugin,
      ctx: ctx,
      addedTypes: added,
    );
    broadcast('plugin.loaded', {'id': manifest.id, 'version': manifest.version});
    // 提醒：loaded 仅登记以备未来需要，目前未用。
    loaded.length;
  }

  /// 撤销该插件在加载时新增的所有 Capability（id 与 handledTypes 增量快照）。
  Future<void> unload(String id) async {
    final l = _loaded.remove(id);
    if (l == null) return;
    // 每个生效的类型独立可能是某能力的 id（own），由注册表按 id 撤销。
    final types = l.addedTypes;
    // 先按 handledTypes 模式统计出"被本插件注册的所有 capability id"。
    final myIds = <String>{};
    for (final c in registry.all) {
      if (types.contains(c.id)) myIds.add(c.id);
    }
    for (final id2 in myIds) {
      registry.unregisterById(id2);
    }
    await l.plugin.onUnload();
    broadcast('plugin.unloaded', {'id': id});
  }

  /// 安装：从源目录（含 plugin.yaml）整体移到 pluginsDir，并触发加载。
  Future<void> installFromPath(String sourcePath) async {
    final id = p.basename(sourcePath);
    final dest = p.join(pluginsDir, id);
    if (Directory(dest).existsSync()) {
      throw StateError('插件 $id 已存在，请先卸载');
    }
    Directory(dest).createSync(recursive: true);
    await Process.run('cp', ['-R', '$sourcePath/.', dest]);
    await load(dest);
  }

  /// 卸载并删除插件目录。
  Future<void> uninstall(String id) async {
    await unload(id);
    final dir = p.join(pluginsDir, id);
    if (Directory(dir).existsSync()) {
      Directory(dir).deleteSync(recursive: true);
    }
    broadcast('plugin.uninstalled', {'id': id});
  }

  /// 列出已加载插件清单（Web UI 用）。
  List<Map<String, Object?>> listPlugins() => _loaded.values
      .map((l) => {
            'id': l.manifest.id,
            'name': l.manifest.name,
            'version': l.manifest.version,
            'author': l.manifest.author,
          })
      .toList();
}

class _Loaded {
  _Loaded({
    required this.manifest,
    required this.plugin,
    required this.ctx,
    required this.addedTypes,
  });
  final PluginManifest manifest;
  final OmniPlayPlugin plugin;
  final PluginContext ctx;
  final Set<String> addedTypes;
}

/// 用户脚本元数据（GreasyMonkey v4 子集）—— scripts.user 插件用。
class UserScript {
  UserScript({
    required this.name,
    required this.version,
    required this.namespace,
    required this.matches,
    required this.runAt,
    required this.code,
    this.excludes = const [],
  });

  final String name;
  final String version;
  final String namespace;
  final List<String> matches;
  final List<String> excludes;
  final String runAt; // 'document-start' | 'document-end' | 'document-idle'
  final String code;

  Map<String, Object?> toJson() => {
        'name': name,
        'version': version,
        'namespace': namespace,
        'matches': matches,
        'excludes': excludes,
        'runAt': runAt,
      };

  static UserScript fromJson(Map<String, Object?> json, String code) {
    return UserScript(
      name: json['name'] as String,
      version: json['version'] as String? ?? '0',
      namespace: json['namespace'] as String? ?? '',
      matches: (json['matches'] as List?)?.cast<String>() ?? const [],
      excludes: (json['excludes'] as List?)?.cast<String>() ?? const [],
      runAt: json['runAt'] as String? ?? 'document-end',
      code: code,
    );
  }
}

/// 用户脚本元数据解析器：识别 GM v4 的 // @name @version @match @run-at 等行。
/// 返回元数据 + 脚本体（不含元数据注释行）。
class UserScriptParser {
  static const _metaPrefix = '//';
  static const _metaKeys = {'@name', '@version', '@namespace', '@match', '@exclude-match', '@run-at', '@description'};

  static ({UserScript script, List<String> warnings}) parse(String source) {
    final meta = <String, List<String>>{};
    final warnings = <String>[];
    final codeLines = <String>[];
    for (final line in source.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith(_metaPrefix)) {
        final body = trimmed.substring(2).trim();
        final space = body.indexOf(' ');
        if (space <= 0) {
          codeLines.add(line);
          continue;
        }
        final key = body.substring(0, space).trim();
        final value = body.substring(space + 1).trim();
        if (_metaKeys.contains(key)) {
          (meta[key] ??= <String>[]).add(value);
          continue;
        }
      }
      codeLines.add(line);
    }
    final matches = <String>[
      for (final k in ['@match', '@exclude-match'])
          for (final v in meta[k] ?? const <String>[]) v,
    ];
    if (matches.isEmpty) warnings.add('脚本缺少 @match，不会自动注入任何页面');
    final script = UserScript(
      name: (meta['@name'] ?? const <String>[]).cast<String>().firstOrNull ?? '',
      version: (meta['@version'] ?? const <String>[]).cast<String>().firstOrNull ?? '0',
      namespace: (meta['@namespace'] ?? const <String>[]).cast<String>().firstOrNull ?? '',
      matches: matches,
      excludes: const [],
      runAt: (meta['@run-at'] ?? const <String>[]).cast<String>().firstOrNull ?? 'document-end',
      code: codeLines.join('\n'),
    );
    return (script: script, warnings: warnings);
  }
}

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}