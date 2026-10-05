import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:node_core/node_core.dart';

/// mDNS 发现通道（发现链路第一层，A1）。
/// bonsoir 是 Flutter 插件，无法进纯 Dart 的 node_core，故适配器放在应用侧，
/// 实现 node_core 的 [DiscoveryChannel] 接口注入 [DiscoveryMerger]。
class BonsoirDiscoveryAdapter implements DiscoveryChannel {
  BonsoirDiscoveryAdapter({
    required this.selfNodeId,
    required this.nodeName,
    required this.httpPort,
  });

  static const serviceType = '_omniplay._tcp';

  final String selfNodeId;
  final String nodeName;
  final int httpPort;

  final _controller = StreamController<DiscoveredNode>.broadcast();
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _discoverySub;

  @override
  Stream<DiscoveredNode> get nodes => _controller.stream;

  @override
  Future<void> start() async {
    final service = BonsoirService(
      // 实例名带 nodeId 短哈希，避免重名设备被系统改写成 "(2)"。
      name: '$nodeName#${selfNodeId.substring(0, 4)}',
      type: serviceType,
      port: httpPort,
      attributes: {'id': selfNodeId, 'ver': '1', 'name': nodeName},
    );

    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.initialize();
    await _broadcast!.start();

    _discovery = BonsoirDiscovery(type: serviceType);
    await _discovery!.initialize();
    await _discovery!.start();
    _discoverySub = _discovery!.eventStream?.listen(_onDiscoveryEvent);
  }

  void _onDiscoveryEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        // 需要 IP，必须 resolve 之后才可用。
        _discovery?.serviceResolver.resolveService(service);
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
        final nodeId = service.attributes['id'];
        final host = service.hostAddresses.isNotEmpty ? service.hostAddresses.first : null;
        if (nodeId == null || host == null || nodeId == selfNodeId) return;
        _controller.add(DiscoveredNode(
          nodeId: nodeId,
          name: service.attributes['name'] ?? service.name,
          host: host,
          httpPort: service.port,
        ));
      case BonsoirDiscoveryServiceLostEvent():
        // 由 DiscoveryMerger 的超时剔除兜底，无需立即处理。
        break;
      default:
        break;
    }
  }

  @override
  Future<void> stop() async {
    await _discoverySub?.cancel();
    await _discovery?.stop();
    await _broadcast?.stop();
    await _controller.close();
  }
}
