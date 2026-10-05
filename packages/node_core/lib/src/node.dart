import 'package:node_protocol/src/envelope.dart';
import 'package:node_protocol/src/messages.dart';

import 'config.dart';
import 'hlc.dart';
import 'discovery.dart';
import 'identity.dart';
import 'library.dart';
import 'node_server.dart';
import 'pairing.dart';
import 'player_adapter.dart';
import 'session.dart';
import 'store.dart';
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
  })  : _playerAdapterFactory = playerAdapterFactory,
        _extraChannels = List.of(discoveryChannels);

  final NodeConfig config;
  final PlayerAdapter Function()? _playerAdapterFactory;
  final List<DiscoveryChannel> _extraChannels;

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
    library = Library(config.mediaDirs);
    pairing = PairingService();
    signer = StreamSigner(_streamSecret());
    session = PlayerSession(nodeId: identity.deviceId, clock: clock, store: store);
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

  String newPin() => pairing.newPin();

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
