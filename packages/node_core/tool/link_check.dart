// 链路验证工具：用本机节点的真实身份认证连接对端节点，验证配对互信与控制面。
//
// 用法（在 packages/node_core 目录下）：
//   dart run tool/link_check.dart <peerHost> [peerPort] [本机数据目录]
//
// 默认数据目录 = macOS 应用沙盒外的 Application Support（omniplay 桌面节点）。
// 打开同一 SQLite 是安全的（WAL 多进程读）。
import 'dart:convert';
import 'dart:io';

import 'package:node_core/node_core.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/link_check.dart <peerHost> [peerPort] [dataDir]');
    exit(2);
  }
  final host = args[0];
  final port = args.length > 1 ? int.tryParse(args[1]) ?? 47771 : 47771;
  final dataDir = args.length > 2
      ? args[2]
      : '${Platform.environment['HOME']}/Library/Application Support/app.omniplay.omniplay/node';

  final store = NodeStore.open(dataDir);
  final identity = await NodeIdentity.loadOrCreate(store);
  final devices = store.listDevices().map((d) => '${d.name}[${d.kind}${d.revoked ? "，已吊销" : ""}]');
  stdout.writeln('本机身份: ${identity.deviceId}');
  stdout.writeln('本机配对名单: ${devices.isEmpty ? "（空）" : devices.join("、")}');

  try {
    final remote = await PlayerRemote.connect(
      host: host,
      port: port,
      deviceName: 'link-check',
      identity: identity,
    );
    stdout.writeln('✅ 已用本机节点身份通过 ${host}:${port} 的认证（配对互信生效）');
    stdout.writeln('对端 hello: ${jsonEncode(remote.hello?.toJson())}');

    PlayerStatePayload? state;
    remote.attachStateSink((s) => state = s);
    await Future<void>.delayed(const Duration(seconds: 2));
    final snapshot = state;
    if (snapshot != null) {
      stdout.writeln(
          '对端播放状态: ${snapshot.state.name} · ${snapshot.title ?? "无媒体"} · 进度 ${snapshot.positionMs}ms · 受控于 ${snapshot.controllerName ?? "无"}');
    }
    final sources = await remote.refreshSources();
    stdout.writeln('对端内容源: ${sources.length} 个${sources.isEmpty ? "" : "（${sources.map((s) => s.name).join("、")}）"}');

    await remote.close();
  } on NeedPinException catch (e) {
    stdout.writeln('❌ 对端不认识本机身份（配对记录未互达）：${e.message}');
  } on Object catch (e) {
    stdout.writeln('❌ 连接失败：$e');
  } finally {
    store.close();
  }
  exit(0);
}
