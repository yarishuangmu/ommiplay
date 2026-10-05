import 'package:flutter/foundation.dart';
import 'package:node_core/node_core.dart';

/// 应用级状态：本节点（含本地播放快照）+ 已建立的控制器连接。
class AppModel extends ChangeNotifier {
  AppModel({required this.node, required this.myName}) {
    node.discovery?.nodes.listen((_) => notifyListeners());
  }

  final Node node;

  /// 本节点在配对与 hello 中使用的显示名。
  final String myName;

  final Map<String, PlayerRemote> _remotes = {};
  PlayerRemote? activeRemote;
  PlayerStatePayload? activeState;
  String? connectionError;

  List<DiscoveredNode> get peers => node.discovery?.snapshot ?? const [];

  PlayerSnapshot get localSnapshot => node.session.snapshot;

  PlayerStatePayload get localPayload => node.session.toPayload();

  /// 本机播放内核（macOS/Android 本机播放页取 VideoController 用）。
  PlayerAdapter? get localPlayer => node.session.adapter;

  Future<PlayerRemote> connect({
    required String host,
    required int port,
    required String name,
    String? pin,
  }) async {
    connectionError = null;
    final key = '$host:$port';
    final existing = _remotes[key];
    if (existing != null) {
      activeRemote = existing;
      notifyListeners();
      return existing;
    }
    try {
      final remote = await PlayerRemote.connect(
        host: host,
        port: port,
        deviceName: myName,
        identity: node.identity,
        pin: pin,
      );
      _remotes[key] = remote;
      remote.attachStateSink((state) {
        activeState = state;
        notifyListeners();
      });
      activeRemote = remote;
      notifyListeners();
      return remote;
    } on NeedPinException {
      // 未配对：UI 弹 PIN 输入后携带 pin 重试。
      notifyListeners();
      rethrow;
    } on Object catch (e) {
      connectionError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disconnectActive() async {
    final remote = activeRemote;
    activeRemote = null;
    activeState = null;
    await remote?.close();
    notifyListeners();
  }

  void addMediaDir(String path) {
    node.addMediaDir(path);
    notifyListeners();
  }

  /// 刷新 PIN（UI 主动换码时调用）。
  void refreshPin() {
    node.newPin();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final remote in _remotes.values) {
      remote.close();
    }
    _remotes.clear();
    super.dispose();
  }
}
