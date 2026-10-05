import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

/// 极简 WebDAV 客户端（仅目录浏览所需的 PROPFIND；文件读取由播放器/代理直连 URL）。
///
/// 命名空间前缀各家服务器不一（d:/D:/DAV:/mx:），统一按 **local name** 匹配。
class WebdavClient {
  WebdavClient({required this.baseUrl, this.username, this.password});

  /// 集合根 URL，如 `http://nas:5005/webdav/媒体/`（建议以 `/` 结尾）。
  final String baseUrl;
  final String? username;
  final String? password;

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/>'
      '</d:prop></d:propfind>';

  String get _authHeader {
    if (username == null || username!.isEmpty) return '';
    final token = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $token';
  }

  /// 拼接 URL：base 的段 + path 的段（逐段编码），保持 base 的尾斜杠语义。
  Uri _uriFor(String path) {
    final base = Uri.parse(baseUrl);
    final trailingSlash = base.path.endsWith('/');
    final segments = [...base.pathSegments];
    if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
    for (final segment in path.split('/')) {
      if (segment.isNotEmpty) segments.add(segment);
    }
    var newPath = segments.isEmpty ? '/' : '/${segments.join('/')}';
    if (path.isEmpty && trailingSlash) newPath = '$newPath/';
    return base.replace(path: newPath);
  }

  String get _basePathDecoded => Uri.decodeFull(Uri.parse(baseUrl).path);

  /// 探测可用性（Depth 0）。失败抛出，成功返回实际响应码（期望 207）。
  Future<int> ping() async {
    final response = await _propfind(_uriFor(''), '0');
    await response.drain<void>();
    return response.statusCode;
  }

  /// 列出 [dirPath] 下的条目（不含目录自身；目录在前、名称排序）。
  Future<List<WebdavEntry>> list(String dirPath) async {
    final response = await _propfind(_uriFor(dirPath), '1');
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 207) {
      throw HttpException('PROPFIND 失败：HTTP ${response.statusCode}');
    }
    final document = XmlDocument.parse(body);

    final entries = <WebdavEntry>[];
    for (final node in document.descendantElements) {
      if (node.name.local != 'response') continue;
      final hrefText = node.descendantElements
          .where((e) => e.name.local == 'href')
          .map((e) => e.innerText)
          .firstOrNull;
      if (hrefText == null) continue;

      final decoded = Uri.decodeFull(hrefText);
      // 排除目录自身（Depth 1 会包含集合本身）。
      final selfPath = _selfPathFor(dirPath);
      if (decoded == selfPath || decoded == '$selfPath/') continue;

      final isDir = node.descendantElements.any((e) => e.name.local == 'collection');
      final sizeText = node.descendantElements
          .where((e) => e.name.local == 'getcontentlength')
          .map((e) => e.innerText)
          .firstOrNull;

      final relative = _relativeOf(decoded);
      if (relative == null || relative.isEmpty) continue;
      final name = relative.split('/').where((s) => s.isNotEmpty).last;
      entries.add(WebdavEntry(
        path: relative,
        name: name,
        isDir: isDir,
        sizeBytes: sizeText == null ? null : int.tryParse(sizeText),
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// 源内文件的可读 URL（供代理转发用，不带凭据）。
  Uri fileUri(String path) => _uriFor(path);

  Map<String, String> get authHeaders =>
      _authHeader.isEmpty ? const {} : {'authorization': _authHeader};

  String _selfPathFor(String dirPath) {
    final basePath = _basePathDecoded;
    final cleanBase = basePath.endsWith('/') ? basePath.substring(0, basePath.length - 1) : basePath;
    final cleanDir = dirPath.endsWith('/') ? dirPath.substring(0, dirPath.length - 1) : dirPath;
    if (cleanDir.isEmpty || cleanDir == '.') return cleanBase;
    return '$cleanBase/$cleanDir';
  }

  /// href（服务器根绝对路径，已解码）→ 源内相对路径；不在集合内则 null。
  String? _relativeOf(String decodedHref) {
    final basePath = _basePathDecoded;
    final withSlash = basePath.endsWith('/') ? basePath : '$basePath/';
    if (!decodedHref.startsWith(withSlash)) return null;
    return decodedHref.substring(withSlash.length);
  }

  Future<HttpClientResponse> _propfind(Uri uri, String depth) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.openUrl('PROPFIND', uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/xml; charset=utf-8');
      request.headers.set('Depth', depth);
      final auth = _authHeader;
      if (auth.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, auth);
      request.add(utf8.encode(_propfindBody));
      final response = await request.close().timeout(const Duration(seconds: 8));
      client.close(force: true);
      return response;
    } on Object {
      client.close(force: true);
      rethrow;
    }
  }
}

class WebdavEntry {
  WebdavEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.sizeBytes,
  });

  final String path;
  final String name;
  final bool isDir;
  final int? sizeBytes;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
