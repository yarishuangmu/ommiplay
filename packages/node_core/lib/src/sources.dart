import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:node_protocol/node_protocol.dart';

import 'utils.dart';
import 'webdav.dart';

/// 播放流描述：源节点如何拿到某个文件的字节。
/// - local：本机文件路径（/stream 直接 Range 读盘）；
/// - remote：上游 URL（/stream 代理转发，附 [headers]，如 WebDAV Basic Auth——
///   凭据只留在源节点，不下发给播放器）。
class StreamRef {
  StreamRef.local(String path)
      : kind = 'local',
        localPath = path,
        remoteUrl = null,
        headers = const {};

  StreamRef.remote(this.remoteUrl, {this.headers = const {}})
      : kind = 'remote',
        localPath = null;

  final String kind;
  final String? localPath;
  final String? remoteUrl;
  final Map<String, String> headers;
}

/// 内容源抽象。新源类型（Emby、m3u、SMB 网关…）实现本接口即可接入
/// 浏览/投片/远端管理三件套（D10 预留插槽）。
abstract class ContentSource {
  SourceInfo get info;

  Future<List<LibEntry>> browse(String dirPath);

  Future<StreamRef> resolveStream(String path);

  /// 持久化配置（含凭据；v1 明文存本节点 SQLite，见 docs 威胁模型）。
  Map<String, Object?> toConfig();

  static ContentSource fromConfig(Map<String, Object?> json) {
    switch (json['kind']) {
      case 'webdav':
        return WebdavSource.fromConfig(json);
      case 'folder':
      default:
        return FolderSource.fromConfig(json);
    }
  }
}

/// 本机目录源（M0 默认；OS 挂载的 SMB/NFS 也走这里）。
class FolderSource implements ContentSource {
  FolderSource(String root) : root = p.normalize(root);

  FolderSource.fromConfig(Map<String, Object?> json) : this(json['root'] as String);

  final String root;

  @override
  SourceInfo get info => SourceInfo(
        sourceId: fnv1aHash('folder|$root'),
        name: p.basename(root),
        root: root,
        kind: 'folder',
      );

  @override
  Future<List<LibEntry>> browse(String dirPath) async {
    final absolute = resolveWithinRoot(root, dirPath.isEmpty ? '.' : dirPath);
    final dir = Directory(absolute);
    if (!dir.existsSync()) throw StateError('目录不存在：$dirPath');

    final entries = <LibEntry>[];
    for (final entity in dir.listSync(followLinks: false)) {
      final base = p.basename(entity.path);
      if (base.startsWith('.')) continue;
      if (entity is Directory) {
        entries.add(LibEntry(name: base, path: p.join(dirPath, base), isDir: true));
      } else if (entity is File) {
        entries.add(LibEntry(
          name: base,
          path: p.join(dirPath, base),
          isDir: false,
          sizeBytes: entity.lengthSync(),
        ));
      }
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<StreamRef> resolveStream(String path) async {
    final absolute = resolveWithinRoot(root, path);
    if (!File(absolute).existsSync()) throw StateError('文件不存在：$path');
    return StreamRef.local(absolute);
  }

  @override
  Map<String, Object?> toConfig() => {'kind': 'folder', 'root': root};
}

/// WebDAV 网络源（家庭 NAS 标配协议；纯 Dart 实现，无需 OS 挂载）。
class WebdavSource implements ContentSource {
  WebdavSource({
    required String url,
    this.username,
    this.password,
    String? name,
  })  : url = url.endsWith('/') ? url : '$url/',
        displayName = name {
    _client = WebdavClient(baseUrl: this.url, username: username, password: password);
  }

  WebdavSource.fromConfig(Map<String, Object?> json)
      : this(
          url: json['url'] as String,
          username: json['username'] as String?,
          password: json['password'] as String?,
          name: json['name'] as String?,
        );

  late final WebdavClient _client;

  final String url;
  final String? username;
  final String? password;
  final String? displayName;

  @override
  SourceInfo get info => SourceInfo(
        sourceId: fnv1aHash('webdav|$url'),
        name: displayName ?? Uri.parse(url).host,
        root: url,
        kind: 'webdav',
      );

  /// 添加源时的可达性校验（PROPFIND Depth 0）。
  Future<int> ping() => _client.ping();

  @override
  Future<List<LibEntry>> browse(String dirPath) async {
    final entries = await _client.list(dirPath);
    return [
      for (final e in entries)
        LibEntry(name: e.name, path: e.path, isDir: e.isDir, sizeBytes: e.sizeBytes),
    ];
  }

  @override
  Future<StreamRef> resolveStream(String path) async {
    return StreamRef.remote(_client.fileUri(path).toString(), headers: _client.authHeaders);
  }

  @override
  Map<String, Object?> toConfig() => {
        'kind': 'webdav',
        'url': url,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
        if (displayName != null) 'name': displayName,
      };
}
