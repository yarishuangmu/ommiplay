import 'dart:io';

import 'package:node_core/node_core.dart';
import 'package:test/test.dart';

/// 计数能力：测试用，验证 PluginManager 能正确注册/撤销。
class _CountingCap implements NodeCapability {
  _CountingCap(this._id);
  final String _id;

  @override
  String get id => _id;
  @override
  Set<String> get handledTypes => {'demo.count'};
  @override
  bool get supported => true;
  int calls = 0;
  @override
  Map<String, Object?> status() => {'id': id, 'supported': supported};

  @override
  Future<bool> handle(msg) async {
    calls++;
    return true;
  }
}

class _TestPlugin implements OmniPlayPlugin {
  _TestPlugin(this.capId);
  final String capId;
  bool loaded = false;
  bool unloaded = false;

  @override
  PluginManifest get manifest => PluginManifest(id: 'demo.test', name: 'demo', version: '0.1.0');

  @override
  Future<void> onLoad(PluginContext context) async {
    loaded = true;
    context.registry.register(_CountingCap(capId));
  }

  @override
  Future<void> onUnload() async {
    unloaded = true;
  }
}

String _writePlugin(String dir, String manifestYaml) {
  final d = Directory(dir)..createSync(recursive: true);
  File('${d.path}/plugin.yaml').writeAsStringSync(manifestYaml);
  return d.path;
}

void main() {
  late Directory tempDir;
  late CapabilityRegistry registry;
  late PluginManager pm;
  late List<Map<String, Object?>> events;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('omniplay-plugins-');
    registry = CapabilityRegistry();
    events = [];
    pm = PluginManager(
      pluginsDir: tempDir.path,
      registry: registry,
      broadcast: (event, data) => events.add({'event': event, ...data}),
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('插件加载注册能力、卸载撤销（增量回滚）', () async {
    final plugin = _TestPlugin('counter-a');
    pm.registerBuiltIn(plugin);

    final pluginDir = _writePlugin(tempDir.path + '/demo1', '''
id: demo1
name: Demo1
version: '0.1.0'
''');
    final manifestDir = _writePlugin(pluginDir, 'id: demo1\nname: Demo1\nversion: "0.1.0"\n');

    // 真正测试 plugin manager：把 plugin.yaml 重写到正确位置
    File('${manifestDir}/plugin.yaml').writeAsStringSync('id: demo.test\nname: demo\nversion: "0.1.0"\n');
    await pm.load(manifestDir);

    expect(plugin.loaded, isTrue);
    expect(registry.findByType('demo.count'), isNotNull);

    await pm.unload('demo.test');
    expect(plugin.unloaded, isTrue);
    expect(registry.findByType('demo.count'), isNull);
  });

  test('扫描空目录不报错', () async {
    final errs = await pm.scanAndLoad();
    expect(errs, isEmpty);
    expect(pm.listPlugins(), isEmpty);
  });

  test('扫描加载全部插件 + 错误隔离', () async {
    final testPlugin = _TestPlugin('counter');
    pm.registerBuiltIn(testPlugin);

    _writePlugin('${tempDir.path}/a', 'id: demo.test\nname: a\nversion: "0.1.0"\n');
    _writePlugin('${tempDir.path}/b', 'id: demo.test\nname: b\nversion: "0.1.0"\n');

    final errs = await pm.scanAndLoad();
    expect(errs, isEmpty);
    // 两个目录同 id：后者被前者覆盖（registerBuiltIn 同 id 也覆盖）→ 最终仅 1 个。
    expect(pm.listPlugins().length, 1);
  });
}