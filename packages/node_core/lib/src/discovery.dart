import 'dart:async';

/// 发现到的节点（一个节点可能同时经 mDNS 与 UDP 信标被看到，由 [DiscoveryMerger] 去重）。
class DiscoveredNode {
  DiscoveredNode({
    required this.nodeId,
    required this.name,
    required this.host,
    required this.httpPort,
    this.protoVer = 1,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String nodeId;
  String name;
  String host;
  int httpPort;
  final int protoVer;
  DateTime lastSeen;

  DiscoveredNode copyWith({String? name, String? host, int? httpPort, int? protoVer, DateTime? lastSeen}) =>
      DiscoveredNode(
        nodeId: nodeId,
        name: name ?? this.name,
        host: host ?? this.host,
        httpPort: httpPort ?? this.httpPort,
        protoVer: protoVer ?? this.protoVer,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// 发现通道抽象：mDNS（Flutter 侧 bonsoir 适配器）与 UDP 信标（本包实现）共用。
abstract class DiscoveryChannel {
  /// 节点出现/更新时推送。
  Stream<DiscoveredNode> get nodes;

  Future<void> start();
  Future<void> stop();
}

/// 多通道合并去重：同 nodeId 取最新，离线（超时未见）节点剔除。
class DiscoveryMerger implements DiscoveryChannel {
  DiscoveryMerger(
    List<DiscoveryChannel> channels, {
    this.pruneAfter = const Duration(seconds: 90),
  }) : _channels = List.of(channels);

  final List<DiscoveryChannel> _channels;
  final Duration pruneAfter;

  final _controller = StreamController<DiscoveredNode>.broadcast();
  final Map<String, DiscoveredNode> _byId = {};
  Timer? _pruner;
  bool _started = false;

  @override
  Stream<DiscoveredNode> get nodes => _controller.stream;

  /// 当前在线快照（UI 可直接读取后渲染）。
  List<DiscoveredNode> get snapshot {
    _prune();
    return _byId.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void addChannel(DiscoveryChannel channel) {
    _channels.add(channel);
    if (_started) _listen(channel);
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final channel in _channels) {
      _listen(channel);
      try {
        await channel.start();
      } on Object catch (_) {
        // 单通道启动失败（端口/权限等）不拖垮节点启动，其余通道继续兜底。
      }
    }
    _pruner = Timer.periodic(const Duration(seconds: 10), (_) => _prune());
  }

  @override
  Future<void> stop() async {
    _pruner?.cancel();
    for (final channel in _channels) {
      await channel.stop();
    }
    await _controller.close();
  }

  void _listen(DiscoveryChannel channel) {
    channel.nodes.listen(
      (node) {
        final existing = _byId[node.nodeId];
        if (existing == null) {
          _byId[node.nodeId] = node;
          _controller.add(node);
        } else {
          existing
            ..name = node.name
            ..host = node.host
            ..httpPort = node.httpPort
            ..lastSeen = node.lastSeen;
          _controller.add(existing);
        }
      },
      // 单通道异常不拖垮合并器。
      onError: (Object _) {},
    );
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(pruneAfter);
    final gone = _byId.values.where((n) => n.lastSeen.isBefore(cutoff)).toList();
    for (final node in gone) {
      _byId.remove(node.nodeId);
    }
  }
}
