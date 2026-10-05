import 'dart:math';

/// 当前协议版本。大版本不兼容（握手即拒），小版本向后兼容。
const int protocolVersion = 1;

/// WS 消息封套。所有节点间消息统一为：
/// `{"v":1,"type":"player.cmd.play","id":"<uuid>","ts":"<hlc>","from":"<nodeId>","payload":{...}}`
class Msg {
  Msg({
    this.v = protocolVersion,
    required this.type,
    required this.id,
    required this.ts,
    required this.from,
    this.payload = const {},
  });

  final int v;
  final String type;
  final String id;

  /// HLC 时间戳（字符串，字典序 == 时间序），由发送方的 HlcClock 生成。
  final String ts;

  /// 发送方 nodeId。
  final String from;

  final Map<String, Object?> payload;

  /// 便捷取 payload 字段，缺失抛 [ArgumentError]。
  T p<T>(String key) {
    final value = payload[key];
    if (value is T) return value;
    throw ArgumentError('消息 $type 缺少或类型不符的字段 "$key"（期望 $T，实际 ${value.runtimeType}）');
  }

  /// 便捷取可空 payload 字段。
  T? pOrNull<T>(String key) => payload[key] is T ? payload[key] as T : null;

  Map<String, Object?> toJson() => {
        'v': v,
        'type': type,
        'id': id,
        'ts': ts,
        'from': from,
        'payload': payload,
      };

  /// 解析并做结构校验，坏消息抛 [FormatException]。
  static Msg fromJson(Object? json) {
    if (json is! Map) throw const FormatException('消息不是 JSON 对象');
    final v = json['v'];
    if (v is! int) throw const FormatException('缺少整数字段 v');
    if (v > protocolVersion) {
      throw FormatException('对端协议版本 $v 高于本端 $protocolVersion，拒绝解析');
    }
    final type = json['type'];
    if (type is! String || type.isEmpty) throw const FormatException('缺少字段 type');
    final ts = json['ts'];
    if (ts is! String || ts.isEmpty) throw const FormatException('缺少字段 ts');
    final from = json['from'];
    if (from is! String || from.isEmpty) throw const FormatException('缺少字段 from');
    return Msg(
      v: v,
      type: type,
      id: (json['id'] is String && (json['id'] as String).isNotEmpty)
          ? json['id'] as String
          : newMsgId(),
      ts: ts,
      from: from,
      payload: json['payload'] is Map
          ? Map<String, Object?>.from(json['payload'] as Map)
          : const {},
    );
  }
}

final Random _random = Random.secure();

/// 16 字节随机 hex，用作消息 id / 令牌等。
String newMsgId() => randomHex(16);

String randomHex(int bytes) {
  final values = List<int>.generate(bytes, (_) => _random.nextInt(256));
  return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
