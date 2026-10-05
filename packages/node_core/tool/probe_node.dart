// 节点探测工具：验证局域网内 OmniPlay 节点的三层可达性。
//
// 用法（在 packages/node_core 目录下）：
//   dart run tool/probe_node.dart <host> [port]
//
// 探测项：
//   1. HTTP  /            —— 节点 HTTP 服务是否在线（返回占位页/控制页）
//   2. UDP   47770 信标   —— 信标通道是否应答（应答含 nodeId/name/port）
//   3. WS    /ws 认证握手 —— 用一次性临时身份连接：被拒(NeedPin)=节点在线且本设备未配对；
//                            认证通过=本设备已与该节点配对过。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:node_core/node_core.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.tryParse(args[1]) ?? 47771 : 47771;
  stdout.writeln('probing OmniPlay node $host:$port\n');

  // 1. HTTP
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final request = await client.getUrl(Uri.parse('http://$host:$port/'));
    final response = await request.close().timeout(const Duration(seconds: 4));
    final text = await response.transform(utf8.decoder).join();
    final plain = text.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    stdout.writeln(
        '[HTTP]  ✅ ${response.statusCode}  ${plain.isEmpty ? '(空页面)' : plain.substring(0, plain.length.clamp(0, 80))}');
    client.close();
  } on Object catch (e) {
    stdout.writeln('[HTTP]  ❌ $e');
  }

  // 2. UDP 信标
  final beacon = await _beaconProbe(host);
  stdout.writeln('[信标]  $beacon');

  // 3. WS 认证握手（一次性临时身份）
  final tmp = await Directory.systemTemp.createTemp('omniplay-probe-');
  try {
    final identity = await NodeIdentity.loadOrCreate(NodeStore.open(tmp.path));
    try {
      final remote = await PlayerRemote.connect(
        host: host,
        port: port,
        deviceName: 'probe',
        identity: identity,
      );
      stdout.writeln('[WS]    ✅ 认证通过 —— 该节点已与本设备配对。hello=${remote.hello?.toJson()}');
      await remote.close();
    } on NeedPinException catch (e) {
      stdout.writeln('[WS]    ✅ 节点在线，拒绝未配对设备（安全模型生效）：${e.message}');
    }
  } on Object catch (e) {
    stdout.writeln('[WS]    ❌ $e');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

Future<String> _beaconProbe(String host) async {
  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } on Object catch (e) {
    return '❌ 绑定失败：$e';
  }
  final payload =
      utf8.encode('OPBEACON1|${jsonEncode({'id': 'probe', 'name': 'probe', 'port': 0, 'ver': 1})}');
  final target = InternetAddress(host);
  final completer = Completer<String>();
  final timer = Timer(const Duration(seconds: 3), () {
    if (!completer.isCompleted) completer.complete('❌ 3 秒内无应答');
  });
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final text = utf8.decode(datagram.data, allowMalformed: true);
    if (!text.startsWith('OPBEACON1|') || completer.isCompleted) return;
    try {
      final json = jsonDecode(text.substring(10)) as Map<String, Object?>;
      if (json['id'] == 'probe') return; // 忽略自己
      timer.cancel();
      completer.complete(
          '✅ 应答自 ${datagram.address.address}：nodeId=${json['id']} name=${json['name']} httpPort=${json['port']} ver=${json['ver']}');
    } on FormatException {
      // 非本协议包，忽略。
    }
  });
  for (var i = 0; i < 3; i++) {
    socket.send(payload, target, 47770);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  final result = await completer.future;
  socket.close();
  timer.cancel();
  return result;
}
