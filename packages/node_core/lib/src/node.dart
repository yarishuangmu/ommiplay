import 'dart:convert';
import 'dart:io';

import 'package:node_protocol/src/envelope.dart';
import 'package:node_protocol/src/messages.dart';

import 'capability.dart';
import 'config.dart';
import 'hlc.dart';
import 'discovery.dart';
import 'gamepad.dart';
import 'identity.dart';
import 'library.dart';
import 'node_server.dart';
import 'sources.dart';
import 'pairing.dart';
import 'player_adapter.dart';
import 'session.dart';
import 'store.dart';
import 'system_control.dart';
import 'stream_signer.dart';
import 'udp_beacon.dart';

/// 一个 OmniPlay 节点（C/P/L 角色按能力注入）。
///
/// 用法（Flutter 应用）：
/// ```dart
/// final node = Node(
///   config: NodeConfig(name: '客厅 Mac', dataDir: dir, mediaDirs: [mediaDir]),
///   playerAdapterFactory: () => MpvPlayerAdapter(...),
///   discoveryChannels: [BonsoirDiscoveryAdapter(...)], // mDNS（Flutter 侧实现）
/// );
/// await node.start();
/// ```
/// 用法（测试/无头）：playerAdapterFactory 省略或返回 FakePlayerAdapter。
class Node {
  Node({
    required this.config,
    PlayerAdapter Function()? playerAdapterFactory,
    List<DiscoveryChannel> discoveryChannels = const [],
    this.systemControl,
    this.webPresenter,
    this.inputController,
    this.gamepadBridge,
  })  : _playerAdapterFactory = playerAdapterFactory,
        _extraChannels = List.of(discoveryChannels);

  final NodeConfig config;
  final PlayerAdapter Function()? _playerAdapterFactory;
  final List<DiscoveryChannel> _extraChannels;

  /// 平台注入的系统能力（桌面全支持，移动端部分支持/不支持）。
  final SystemControl? systemControl;
  final WebPresenter? webPresenter;
  final InputController? inputController;

  /// 手柄桥（桌面=键鼠映射；移动端=null）。null 时按 inputController 桌面性推断。
  final GamepadBridge? gamepadBridge;

  /// 正交能力注册表：新能力零改动接入核心路由（docs/capabilities.md）。
  final CapabilityRegistry capabilities = CapabilityRegistry();

  late final NodeStore store;
  late final NodeIdentity identity;
  late final HlcClock clock;
  late final Library library;
  late final PairingService pairing;
  late final PlayerSession session;
  late final NodeServer server;
  late final StreamSigner signer;
  DiscoveryMerger? discovery;

  bool _started = false;

  String get nodeId => identity.deviceId;

  /// 实际绑定端口（config.httpPort=0 时由系统分配）。
  int get boundPort => server.boundPort;

  /// 其他设备访问本节点的地址（控制页/配对二维码的基础）。
  String get lanUrl => server.lanUrl();

  Future<void> start() async {
    if (_started) return;
    store = NodeStore.open(config.dataDir);
    // familyId：首节点即创始节点 id；M1 对等归集后全网一致。
    if (store.getMeta('family_id') == null) {
      // 此时 identity 尚未加载，先占位；identity 加载后写入。
    }
    identity = await NodeIdentity.loadOrCreate(store);
    if (store.getMeta('family_id') == null) {
      store.setMeta('family_id', identity.deviceId);
    }
    clock = HlcClock(identity.deviceId);
    final storedDirs = (store.getMeta('media_dirs') != null)
        ? (jsonDecode(store.getMeta('media_dirs')!) as List).cast<String>()
        : const <String>[];
    final storedSourceConfigs = (store.getMeta('media_sources') != null)
        ? (jsonDecode(store.getMeta('media_sources')!) as List)
            .map((e) => Map<String, Object?>.from(e as Map))
            .map(ContentSource.fromConfig)
            .toList()
        : <ContentSource>[];
    library = Library([
      ...[...config.mediaDirs, ...storedDirs].map(FolderSource.new),
      ...storedSourceConfigs,
    ]);
    pairing = PairingService();
    signer = StreamSigner(_streamSecret());
    session = PlayerSession(
      nodeId: identity.deviceId,
      clock: clock,
      store: store,
      systemControl: systemControl,
    );
    server = NodeServer(
      nodeId: identity.deviceId,
      nodeName: config.name,
      store: store,
      identity: identity,
      library: library,
      session: session,
      pairing: pairing,
      signer: signer,
      webRoot: config.webRoot,
      announceHost: config.announceHost,
      onSourceCommand: handleSourceCommand,
      systemControl: systemControl,
      webPresenter: webPresenter,
      inputController: inputController,
    );
    session.onSnapshotChanged = (payload) {
      server.broadcast(Msg(
        type: MsgTypes.playerState,
        id: newMsgId(),
        ts: clock.tick(),
        from: nodeId,
        payload: payload.toJson(),
      ));
    };
    final factory = _playerAdapterFactory;
    if (factory != null) {
      session.attach(factory());
    }
    // 内置正交能力注册（新能力零改动接入，docs/capabilities.md）。
    final gamepad = gamepadBridge;
    if (gamepad != null) {
      capabilities.register(GamepadCapability(gamepad));
    }
    server.capabilitiesRegistry.registerAll(capabilities.all);
    await server.start(port: config.httpPort);

    final channels = List.of(_extraChannels);
    if (config.udpPort != null) {
      channels.add(UdpBeaconChannel(
        selfNodeId: nodeId,
        name: config.name,
        httpPort: server.boundPort,
        udpPort: config.udpPort!,
        extraAnnounceHosts: const ['127.0.0.1'],
      ));
    }
    if (channels.isNotEmpty) {
      discovery = DiscoveryMerger(channels);
      await discovery!.start();
    }
    _started = true;
  }

  /// 当前有效 PIN（供 UI 展示；可能已过期为 null）。
  String? get currentPin => pairing.currentPin;

  /// 新增本机内容源目录并持久化（Library 角色）。
  void addMediaDir(String path) {
    library.add(FolderSource(path));
    _persistSources();
  }

  /// 新增 WebDAV 网络源（先探测可达性），成功返回 SourceInfo。
  Future<SourceInfo> addWebdavSource({
    required String url,
    String? username,
    String? password,
    String? name,
  }) async {
    final source = WebdavSource(url: url, username: username, password: password, name: name);
    final code = await source.ping();
    if (code != 207) {
      throw StateError('WebDAV 不可达（HTTP $code，期望 207）');
    }
    library.add(source);
    _persistSources();
    return source.info;
  }

  /// 移除内容源（本机/网络均可）。
  void removeSource(String sourceId) {
    library.remove(sourceId);
    _persistSources();
  }

  void _persistSources() {
    store.setMeta('media_sources', jsonEncode(library.configs));
  }

  /// 远端源管理（lib.source.add/remove，已认证控制器可调用）。
  Future<Map<String, Object?>?> handleSourceCommand(String type, Map<String, Object?> payload) async {
    switch (type) {
      case MsgTypes.sourceAdd:
        try {
          final kind = payload['kind'] as String? ?? 'folder';
          final ContentSource source;
          if (kind == 'webdav') {
            source = WebdavSource(
              url: payload['url'] as String? ?? '',
              username: payload['username'] as String?,
              password: payload['password'] as String?,
              name: payload['name'] as String?,
            );
            final code = await (source as WebdavSource).ping();
            if (code != 207) throw StateError('WebDAV 不可达（HTTP \$code）');
          } else if (kind == 'folder') {
            source = FolderSource(payload['path'] as String? ?? '');
            if (!Directory((source as FolderSource).root).existsSync()) {
              throw StateError('目录不存在：\${(source as FolderSource).root}');
            }
          } else {
            throw ArgumentError('未知源类型：\$kind');
          }
          library.add(source);
          _persistSources();
          _broadcastSources();
          return {'ok': true, 'source': source.info.toJson()};
        } on Object catch (e) {
          return {'ok': false, 'error': e.toString()};
        }
      case MsgTypes.sourceRemove:
        library.remove(payload['sourceId'] as String? ?? '');
        _persistSources();
        _broadcastSources();
        return {'ok': true};
      default:
        return null;
    }
  }

  void _broadcastSources() {
    server.broadcast(Msg(
      type: MsgTypes.sources,
      id: newMsgId(),
      ts: clock.tick(),
      from: nodeId,
      payload: server.sourcesPayload(),
    ));
  }

  String newPin() => pairing.newPin();

  /// 生成一次性扫码加入令牌（QR 配对，M0-β）。
  String newJoinToken() => pairing.newJoinToken();

  Future<void> stop() async {
    if (!_started) return;
    await discovery?.stop();
    await session.dispose();
    await server.stop();
    store.close();
    _started = false;
  }

  String _streamSecret() {
    var secret = store.getMeta('stream_secret');
    if (secret == null) {
      secret = StreamSigner.newSecret();
      store.setMeta('stream_secret', secret);
    }
    return secret;
  }
}
