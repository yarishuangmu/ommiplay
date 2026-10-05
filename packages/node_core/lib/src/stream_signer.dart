import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:node_protocol/src/envelope.dart';

/// 签名流 URL（A5）：`/stream/<token>`，token = base64url(`sourceId|path|expiresMs|hmac`)。
/// 播放器拿 URL 后用 HTTP Range 直接向源节点拉流，控制面与数据面分离。
class StreamSigner {
  StreamSigner(String secret)
      : _hmac = crypto.Hmac(crypto.sha256, utf8.encode(secret));

  final crypto.Hmac _hmac;

  String sign({
    required String sourceId,
    required String path,
    Duration ttl = const Duration(hours: 2),
  }) {
    final expiresMs = DateTime.now().add(ttl).millisecondsSinceEpoch;
    final payload = '$sourceId|$path|$expiresMs';
    final sig = _hmac.convert(utf8.encode(payload)).toString();
    return base64Url
        .encode(utf8.encode('$payload|$sig'))
        .replaceAll('=', '');
  }

  ({String sourceId, String path})? verify(String token) {
    // base64Url 无填充解码：补齐 '='。
    final normalized = base64Url.normalize(token);
    final String decoded;
    try {
      decoded = utf8.decode(base64Url.decode(normalized));
    } on FormatException {
      return null;
    }
    final parts = decoded.split('|');
    if (parts.length != 4) return null;
    final sourceId = parts[0];
    final path = parts[1];
    final expiresMs = int.tryParse(parts[2]);
    final sig = parts[3];
    if (expiresMs == null) return null;
    if (DateTime.now().millisecondsSinceEpoch > expiresMs) return null;
    final expected = _hmac.convert(utf8.encode('$sourceId|$path|$expiresMs')).toString();
    if (sig != expected) return null;
    return (sourceId: sourceId, path: path);
  }

  /// 生成节点流签名密钥（首次启动持久化用）。
  static String newSecret() => randomHex(32);
}
