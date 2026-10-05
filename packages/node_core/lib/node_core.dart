/// OmniPlay 节点核心（纯 Dart，无 Flutter 依赖）。
///
/// 分层：发现（mDNS 适配器在 Flutter 侧 / UDP 信标在此）→ 配对 →
/// 控制协议（WS）→ 播放会话 → 内容源与流服务 → 本地存储。
/// 规范见仓库 docs/protocol.md 与 docs/architecture.md。
library node_core;

export 'package:node_protocol/src/envelope.dart';
export 'package:node_protocol/src/messages.dart';

export 'src/config.dart';
export 'src/discovery.dart';
export 'src/hlc.dart';
export 'src/identity.dart';
export 'src/library.dart';
export 'src/node.dart';
export 'src/node_server.dart';
export 'src/pairing.dart';
export 'src/player_adapter.dart';
export 'src/player_remote.dart';
export 'src/session.dart';
export 'src/store.dart';
export 'src/stream_signer.dart';
export 'src/udp_beacon.dart';
export 'src/utils.dart';
