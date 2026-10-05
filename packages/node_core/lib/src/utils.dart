import 'dart:io';

import 'package:path/path.dart' as p;

/// 探测本机主局域网 IPv4；找不到则回退 127.0.0.1（测试/单机场景）。
Future<String> detectLanAddress() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        // 排除 Tailscale/CGNAT（100.64.0.0/10）等虚拟网段，优先真实局域网地址。
        final octets = address.address.split('.');
        if (octets.length == 4) {
          final first = int.parse(octets[0]);
          final second = int.parse(octets[1]);
          if (first == 100 && second >= 64 && second <= 127) continue;
        }
        return address.address;
      }
    }
  } on SocketException {
    // 忽略，走回退。
  }
  return InternetAddress.loopbackIPv4.address;
}

/// 将内容源根目录下的相对路径解析为绝对路径，并确保不越出根目录。
String resolveWithinRoot(String root, String relative) {
  final normalizedRoot = p.normalize(p.absolute(root));
  final normalized = p.normalize(p.join(normalizedRoot, relative));
  if (normalized != normalizedRoot && !p.isWithin(normalizedRoot, normalized)) {
    throw ArgumentError('路径越界：$relative');
  }
  return normalized;
}

/// FNV-1a 32 位哈希（hex）。仅用于 sourceId 等非安全场景。
String fnv1aHash(String input) {
  var hash = 0x811c9dc5;
  for (final code in input.codeUnits) {
    hash ^= code & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash ^= code >> 8;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
