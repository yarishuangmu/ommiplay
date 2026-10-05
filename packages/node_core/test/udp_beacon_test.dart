import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:node_core/src/udp_beacon.dart';
import 'package:test/test.dart';

/// 回归背景（M0-α 真实事故）：macOS 上向 255.255.255.255 发送会以**异步** socket
/// 错误（EACCES，无 SO_BROADCAST）打在 listen 的 onError 上；旧实现未接 onError，
/// 订阅被取消、信标静默死亡，且异常沿 Node.start 炸掉整个应用启动。
/// 本测试锁定"监听 + 单播回包"路径必须存活。广播/组播的跨机投递属网络环境问题，
/// 由真机验收（S1）覆盖，不在 CI 断言。
void main() {
  test('信标：收到单播探测包后应答（含 nodeId/name/port）', () async {
    final port = 40000 + DateTime.now().millisecondsSinceEpoch % 20000;
    final channel = UdpBeaconChannel(
      selfNodeId: 'node-a',
      name: '节点A',
      httpPort: 47771,
      udpPort: port,
    );
    await channel.start();
    addTearDown(channel.stop);

    // 收集本通道看到的发现事件。
    final seen = <Map<String, Object?>>[];
    final sub = channel.nodes.listen(
      (node) => seen.add({'id': node.nodeId, 'host': node.host}),
    );
    addTearDown(sub.cancel);

    // 模拟另一台设备：从临时 socket 发单播探测包。
    final probe = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(probe.close);
    final reply = Completer<String>();
    probe.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = probe.receive();
      if (d == null) return;
      final text = utf8.decode(d.data, allowMalformed: true);
      if (text.startsWith('OPBEACON1|') && !reply.isCompleted) {
        reply.complete(text.substring('OPBEACON1|'.length));
      }
    }, onError: (Object _) {});

    final packet = utf8.encode(
      'OPBEACON1|${jsonEncode({'id': 'node-b', 'name': '节点B', 'port': 47771, 'ver': 1})}',
    );
    probe.send(packet, InternetAddress.loopbackIPv4, port);

    final payload =
        jsonDecode(await reply.future.timeout(const Duration(seconds: 3))) as Map<String, Object?>;
    expect(payload['id'], 'node-a');
    expect(payload['name'], '节点A');
    expect(payload['port'], 47771);

    // 探测方（node-b）也应进入本通道的发现列表。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.map((e) => e['id']), contains('node-b'));
  });

  test('信标：收到非协议垃圾包后仍能正常应答（socket 不被错误杀死）', () async {
    final port = 40000 + DateTime.now().millisecondsSinceEpoch % 20000;
    final channel = UdpBeaconChannel(
      selfNodeId: 'node-a',
      name: 'A',
      httpPort: 1,
      udpPort: port,
    );
    await channel.start();
    addTearDown(channel.stop);

    final noise = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(noise.close);
    noise.send(utf8.encode('not-a-beacon'), InternetAddress.loopbackIPv4, port);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final probe = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(probe.close);
    final reply = Completer<bool>();
    probe.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = probe.receive();
      if (d != null && !reply.isCompleted) reply.complete(true);
    }, onError: (Object _) {});
    probe.send(
      utf8.encode('OPBEACON1|${jsonEncode({'id': 'node-b', 'name': 'B', 'port': 2, 'ver': 1})}'),
      InternetAddress.loopbackIPv4,
      port,
    );
    expect(await reply.future.timeout(const Duration(seconds: 3)), isTrue);
  });
}
