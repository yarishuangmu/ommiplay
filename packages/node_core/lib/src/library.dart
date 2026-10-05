import 'package:node_protocol/node_protocol.dart';

import 'sources.dart';

/// Library 角色：把本节点登记的内容源（本机目录/网络源）统一提供给全网。
/// 浏览与拉流协议对 UI 完全一致，源类型差异封装在 [ContentSource] 内。
class Library {
  Library(List<ContentSource> sources) : _sources = List.of(sources);

  final List<ContentSource> _sources;

  int get length => _sources.length;

  bool contains(String sourceId) => _sources.any((s) => s.info.sourceId == sourceId);

  List<SourceInfo> get sources => _sources.map((s) => s.info).toList();

  /// 全部源的持久化配置（Node 写入 store.meta）。
  List<Map<String, Object?>> get configs => _sources.map((s) => s.toConfig()).toList();

  void add(ContentSource source) {
    _sources.removeWhere((s) => s.info.sourceId == source.info.sourceId);
    _sources.add(source);
  }

  void remove(String sourceId) {
    _sources.removeWhere((s) => s.info.sourceId == sourceId);
  }

  ContentSource? sourceById(String sourceId) {
    for (final source in _sources) {
      if (source.info.sourceId == sourceId) return source;
    }
    return null;
  }

  /// 列出某个源下相对目录 [dirPath] 的条目（目录在前，名称排序）。
  Future<List<LibEntry>> browse({required String sourceId, required String dirPath}) async {
    final source = _require(sourceId);
    return source.browse(dirPath);
  }

  /// 解析某个文件的流描述（local=本机路径 / remote=上游 URL + 认证头）。
  Future<StreamRef> resolveStream({required String sourceId, required String path}) async {
    final source = _require(sourceId);
    return source.resolveStream(path);
  }

  ContentSource _require(String sourceId) {
    final source = sourceById(sourceId);
    if (source == null) throw ArgumentError('未知内容源 $sourceId');
    return source;
  }
}
