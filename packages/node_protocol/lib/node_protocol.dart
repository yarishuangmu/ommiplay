/// OmniPlay 节点间 WS 消息协议（v1）。
///
/// 封套见 [Msg]；消息类型常量与载荷模型见 [MsgTypes] 与各 payload 类。
/// 规范文档：docs/protocol.md。
library node_protocol;

export 'src/envelope.dart';
export 'src/messages.dart';
