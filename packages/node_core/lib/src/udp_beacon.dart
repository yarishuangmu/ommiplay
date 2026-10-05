import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:node_protocol/src/envelope.dart';

import 'config.dart';
import 'discovery.dart';

/// UDP 信标（发现链路第二层兜底，A1/R5）。
///
/// 协议：一包一行 `"OPBEACON1|{json}"`，json 为 `{id,name,port,ver}`。
///
/// 发送通道（平台能力不同，按可用性叠加，全部失败静默）：
/// - **组播** `239.255.77.88`（主通道）：macOS/Windows/Linux/Android 皆可用，
///   接收方需 `joinMulticast`；
/// - **广播** `255.255.255.255`：macOS 未暴露 SO_BROADCAST，发送会异步 EACCES
///   （实测 dart 3.13），因此广播只从**专用短命 socket** 发出并吞掉其错误，
///   不影响主监听 socket；Linux/Android 上真实生效；
/// - **单播** `127.0.0.1`：本机多实例互通/测试。
///
/// 收到任何信标包都**单播回包**：只要一方能到达另一方，双向即可互见。
class UdpBeaconChannel implements DiscoveryChannel {
  UdpBeaconChannel({
    required this.selfNodeId,
    required this.name,
    required this.httpPort,
    this.udpPort = NodeConfig.defaultUdpPort,
    this.protoVer = protocolVersion,
    List<String> extraAnnounceHosts = const [],
  }) : _extraHosts = extraAnnounceHosts;

  /// OmniPlay 专用组播组（站点局部范围，不与 mDNS 的 5353 冲突）。
  static final InternetAddress multicastAddress = InternetAddress('239.255.77.88');

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
    try {
      socket.joinMulticast(multicastAddress);
    } on Object catch (_) {
      // 组播加入失败（如无组播路由）：单播回包与广播通道仍可用。
    }
    // onError 必须接住：macOS 上广播发送的 EACCES 以异步错误形式出现在这里，
    // 若不接住，订阅会被取消、信标通道静默死亡（M0-α 的真实事故）。
    socket.listen(_onEvent, onError: (Object _) {});

    await announce();
  }

  /// 主动宣告一轮。也供网络变化时手动触发。
  Future<void> announce() async {
    final socket = _socket;
    if (socket == null) return;
    final data = utf8.encode('$_magic|${_payload()}');

    // 主 socket：组播 + 本机单播（同步 send 也可能抛错，安全包裹）。
    _safeSend(socket, data, multicastAddress);
    _safeSend(socket, data, InternetAddress.loopbackIPv4);
    for (final host in _extraHosts) {
      _safeSend(socket, data, InternetAddress(host));
    }

    // 广播走专用短命 socket：其异步错误随 socket 一起被丢弃，不伤主通道。
    RawDatagramSocket? blast;
    try {
      blast = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      blast.listen((_) {}, onError: (Object _) {});
      _safeSend(blast, data, InternetAddress('255.255.255.255'));
    } on Object catch (_) {
      // 无广播能力（权限/平台限制）：静默降级。
    } finally {
      Timer(const Duration(seconds: 2), () => blast?.close());
    }

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => announce());
  }

  /// [port] 缺省时发到本节点的信标端口（宣告语义）；回包必须显式传发送方源端口。
  void _safeSend(RawDatagramSocket socket, List<int> data, InternetAddress address,
      {int? port}) {
    try {
      socket.send(data, address, port ?? udpPort);
    } on Object catch (_) {
      // 单个目标失败不阻塞其他通道。
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    _onPacket(datagram);
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

    // 收到即回包（单播，发到发送方的源端口）：即便宣告是单向的也能互见。
    final socket = _socket;
    if (socket != null) {
      _safeSend(socket, utf8.encode('$_magic|${_payload()}'), datagram.address,
          port: datagram.port);
    }

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
