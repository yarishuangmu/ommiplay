import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:node_protocol/node_protocol.dart';

import 'utils.dart';

/// Library 角色：把本机媒体目录作为内容源提供给全网（M0 仅本地文件夹）。
class Library {
  Library(List<String> mediaDirs) : _roots = mediaDirs.map(p.normalize).toList();

  final List<String> _roots;

  /// 当前内容源根目录（持久化用）。
  List<String> get roots => List.unmodifiable(_roots);

  /// 运行时新增内容源（如用户在界面选择媒体目录）。
  void addRoot(String dir) {
    final normalized = p.normalize(dir);
    if (!_roots.contains(normalized)) _roots.add(normalized);
  }

  List<SourceInfo> get sources => [
        for (final root in _roots)
          SourceInfo(
            sourceId: fnv1aHash(root),
            name: p.basename(root),
            root: root,
          ),
      ];

  SourceInfo? sourceById(String sourceId) {
    for (final i in sources) {
      if (i.sourceId == sourceId) return i;
    }
    return null;
  }

  /// 列出内容源下某个相对目录的条目（目录在前，名称排序）。
  List<LibEntry> browse({required String sourceId, required String dirPath}) {
    final source = sourceById(sourceId);
    if (source == null) throw ArgumentError('未知内容源 $sourceId');
    final absolute = resolveWithinRoot(source.root, dirPath.isEmpty ? '.' : dirPath);
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

  /// 把相对路径解析为绝对文件路径（流服务用），带越界防护。
  String resolveFile({required String sourceId, required String path}) {
    final source = sourceById(sourceId);
    if (source == null) throw ArgumentError('未知内容源 $sourceId');
    final absolute = resolveWithinRoot(source.root, path);
    if (!File(absolute).existsSync()) throw StateError('文件不存在：$path');
    return absolute;
  }
}
