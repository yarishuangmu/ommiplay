import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:node_protocol/src/envelope.dart';

import 'config.dart';
import 'discovery.dart';

/// UDP 广播信标（发现链路第二层兜底，见需求 A1/R5）。
///
/// 协议：一包一行 `"OPBEACON1|{json}"`，json 为 `{id,name,port,ver}`。
/// 节点上线 3 连发（间隔 500ms）+ 每 30s 心跳；收到任何信标包都**单播回包**，
/// 因此只要一方能收到另一方，双向即可互见（应对单向多播被挡的网络）。
class UdpBeaconChannel implements DiscoveryChannel {
  UdpBeaconChannel({
    required this.selfNodeId,
    required this.name,
    required this.httpPort,
    this.udpPort = NodeConfig.defaultUdpPort,
    this.protoVer = protocolVersion,
    List<String> extraAnnounceHosts = const [],
  }) : _extraHosts = extraAnnounceHosts;

  final String selfNodeId;
  final String name;
  final int httpPort;
  final int udpPort;
  final int protoVer;

  /// 额外要单播宣告的地址（测试回环等场景）。
  final List<String> _extraHosts;

  final _controller = StreamController<DiscoveredNode>.broadcast();
  RawDatagramSocket? _socket;
  Timer? _heartbeat;

  static const _magic = 'OPBEACON1';

  @override
  Stream<DiscoveredNode> get nodes => _controller.stream;

  String _payload() => jsonEncode({
        'id': selfNodeId,
        'name': name,
        'port': httpPort,
        'ver': protoVer,
      });

  @override
  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      udpPort,
      reuseAddress: true,
    );
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      _onPacket(datagram);
    });

    await announce();
  }

  /// 主动宣告一轮（3 连发）。也供网络变化时手动触发。
  Future<void> announce() async {
    final socket = _socket;
    if (socket == null) return;
    final data = utf8.encode('$_magic|${_payload()}');
    for (var i = 0; i < 3; i++) {
      for (final host in [..._extraHosts, '255.255.255.255']) {
        try {
          socket.send(data, InternetAddress(host), udpPort);
        } on SocketException {
          // 单个目标失败不阻塞其他目标。
        }
      }
      if (i < 2) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => announce());
  }

  void _onPacket(Datagram datagram) {
    final text = utf8.decode(datagram.data, allowMalformed: true);
    if (!text.startsWith('$_magic|')) return;
    final Map<String, Object?> json;
    try {
      json = jsonDecode(text.substring(_magic.length + 1)) as Map<String, Object?>;
    } on FormatException {
      return;
    }
    final id = json['id'] as String?;
    final port = json['port'] as int?;
    if (id == null || port == null || id == selfNodeId) return;

    // 收到即回包（单播）：即便广播是单向的也能互见。
    _socket?.send(
      utf8.encode('$_magic|${_payload()}'),
      datagram.address,
      datagram.port,
    );

    _controller.add(DiscoveredNode(
      nodeId: id,
      name: (json['name'] as String?) ?? id,
      host: datagram.address.address,
      httpPort: port,
      protoVer: (json['ver'] as int?) ?? 1,
    ));
  }

  @override
  Future<void> stop() async {
    _heartbeat?.cancel();
    _socket?.close();
    _socket = null;
    await _controller.close();
  }
}
