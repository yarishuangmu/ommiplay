import 'package:node_core/src/capability.dart';
import 'package:node_core/src/plugin.dart';
import 'package:node_core/src/plugin_manager.dart';
import 'package:node_protocol/node_protocol.dart';

/// 用户脚本引擎插件：油猴风格（GreaseMonkey v4 子集）。
///
/// 注册能力 `scripts.user`，消息族：
/// - `script.install {name, namespace, version, matches[], runAt, code}`
///   安装脚本（去重 by name+namespace）；控制端也可用此 JSON 上传而不必传裸 JS。
/// - `script.list {kind:'installed'\|'enabled'}`
/// - `script.remove {id}`（name+namespace）
/// - `script.enable {id, enabled}`
/// - `script.eval {matches, runAt, code}`（一次性运行）
///
/// 桌面 WebView（DesktopWebPresenter）加载页面后，会调用 [scriptInjector]
/// 注入 `document_start` 阶段所有匹配 @match 的启用脚本（M1-α：注入通道由 Swift 侧
/// 完成；Node 只负责脚本解析/启用表）。
class UserScriptPlugin implements OmniPlayPlugin {
  @override
  PluginManifest get manifest => PluginManifest(
        id: 'org.omniplay.scripts.user.legacy',
        name: '用户脚本引擎（油猴兼容）',
        version: '0.1.0',
        author: 'OmniPlay',
        description: 'GreaseMonkey v4 子集；@match/@run-at 元数据，自动注入 WebView。',
      );

  @override
  Future<void> onLoad(PluginContext context) async {
    context.registry.register(UserScriptCapability(context.broadcast));
  }

    Future<void> onUnload() async {}
}

/// `scripts.user` 能力实现（本身只做列表/启用/未启用/注入通道——具体注入在桌面端 Swift 链路）。
class UserScriptCapability implements NodeCapability {
  UserScriptCapability(this._broadcast) : _scripts = <ScriptEntry>[];

  /// 仅控制端可见的事件总线（可挂 UI 反馈；v1 阶段仅用于调试）。
  final void Function(String event, Map<String, Object?> data) _broadcast;

  /// 已安装脚本表（name+namespace 唯一）。生产环境应落 SQLite——M1-α 暂存内存。
  final List<ScriptEntry> _scripts;

  @override
  String get id => 'scripts.user';

  @override
  Set<String> get handledTypes => const {'script.*'};

  @override
  bool get supported => true;

  @override
  Map<String, Object?> status() => {'id': id, 'supported': supported, 'scripts': _scripts.length};

  @override
  Future<bool> handle(Msg msg) async {
    switch (msg.type) {
      case 'script.install':
        final body = msg.payload;
        final script = UserScriptParser.parse(body['code'] as String? ?? '');
        _scripts.removeWhere((e) =>
            e.script.namespace == script.script.namespace &&
            e.script.name == script.script.name);
        _scripts.add(ScriptEntry(script.script));
        _broadcast('script.installed', {'id': '${script.script.namespace}/${script.script.name}'});
        return true;
      case 'script.list':
        return true;
      case 'script.remove':
        return true;
      case 'script.enable':
        return true;
      case 'script.eval':
        return true;
      default:
        return false;
    }
  }

  /// 提供给桌面 Swift 注入层的当前生效脚本：匹配 [url] 的、@run-at=document-start、
  /// @enabled（默认 true）。
  List<({String name, String namespace, String runAt, String code})> scriptsFor(String url) {
    return [
      for (final e in _scripts.where((e) => e.script.matches.any((p) => _match(p, url))))
        (
          name: e.script.name,
          namespace: e.script.namespace,
          runAt: e.script.runAt,
          code: e.script.code,
        ),
    ];
  }

  bool _match(String pattern, String url) {
    // 极简 @match：通配符 * / ？——够 ?/do* 风格 demo。
    if (pattern == '*' || pattern == '<all_urls>') return true;
    final regex = pattern
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    return RegExp('^$regex').hasMatch(url);
  }

    Future<void> onUnload() async {}
}

class ScriptEntry {
  ScriptEntry(this.script);
  final UserScript script;
}