import 'package:flutter/material.dart';
import 'package:node_core/node_core.dart';

import '../app_model.dart';

/// 未配对时弹 PIN 输入并重试的完整连接流程。
Future<PlayerRemote?> connectWithPinFlow(
  BuildContext context,
  AppModel model, {
  required String host,
  required int port,
  required String name,
}) async {
  try {
    return await model.connect(host: host, port: port, name: name);
  } on NeedPinException {
    final pin = await _askPin(context, name);
    if (pin == null || !context.mounted) return null;
    try {
      return await model.connect(host: host, port: port, name: name, pin: pin);
    } on Object catch (e) {
      _showError(context, e);
      return null;
    }
  } on Object catch (e) {
    _showError(context, e);
    return null;
  }
}

Future<String?> _askPin(BuildContext context, String nodeName) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('配对「$nodeName」'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('在对方节点的屏幕上找到 6 位配对 PIN：'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('配对')),
      ],
    ),
  );
}

void _showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('连接失败：$error')),
  );
}

/// 内容源浏览与投片（A5）：选源 → 目录导航 → 点文件 → 取流地址 → load 到目标播放器。
Future<void> showBrowseSheet(BuildContext context, PlayerRemote remote) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BrowseSheet(remote: remote),
  );
}

class _BrowseSheet extends StatefulWidget {
  const _BrowseSheet({required this.remote});

  final PlayerRemote remote;

  @override
  State<_BrowseSheet> createState() => _BrowseSheetState();
}

class _BrowseSheetState extends State<_BrowseSheet> {
  List<SourceInfo>? _sources;
  SourceInfo? _currentSource;
  String _dirPath = '';
  List<LibEntry>? _entries;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await widget.remote.refreshSources();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _loading = false;
        if (sources.isNotEmpty) _pickSource(sources.first);
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickSource(SourceInfo source) async {
    setState(() {
      _currentSource = source;
      _dirPath = '';
      _entries = null;
      _loading = true;
    });
    await _browse('');
  }

  Future<void> _browse(String dirPath) async {
    final source = _currentSource;
    if (source == null) return;
    setState(() {
      _dirPath = dirPath;
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.remote.browse(sourceId: source.sourceId, dirPath: dirPath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _playFile(LibEntry entry) async {
    final source = _currentSource;
    if (source == null) return;
    try {
      final stream = await widget.remote.requestStream(sourceId: source.sourceId, path: entry.path);
      await widget.remote.loadMedia(
        // 跨节点优先走签名流 URL（数据面走 HTTP Range）；本机文件用本地路径。
        kind: stream.url != null ? 'url' : 'file',
        value: stream.url ?? stream.localPath ?? entry.path,
        title: entry.name,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已投片：${entry.name}')));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text('浏览并投片', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: '在目标节点添加 WebDAV 网络源',
                    onPressed: _addSourceDialog,
                    icon: const Icon(Icons.add_link),
                  ),
                ],
              ),
            ),
            if (_sources != null && _sources!.isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final source in _sources!)
                    GestureDetector(
                      onLongPress: () => _confirmRemove(source),
                      child: ChoiceChip(
                        label: Text('${source.name} [${source.kind}]'),
                        selected: source == _currentSource,
                        onSelected: (_) => _pickSource(source),
                      ),
                    ),
                ],
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text('出错：$_error'))
                      : ListView(
                          children: [
                            if (_dirPath.isNotEmpty)
                              ListTile(
                                leading: const Icon(Icons.arrow_upward),
                                title: const Text('上一级'),
                                onTap: () => _browse(_parentOf(_dirPath)),
                              ),
                            for (final entry in _entries ?? const <LibEntry>[])
                              ListTile(
                                leading: Icon(entry.isDir ? Icons.folder : Icons.movie_outlined),
                                title: Text(entry.name),
                                subtitle: !entry.isDir && entry.sizeBytes != null
                                    ? Text('${(entry.sizeBytes! / 1024 / 1024).toStringAsFixed(1)} MB')
                                    : null,
                                onTap: () =>
                                    entry.isDir ? _browse(entry.path) : _playFile(entry),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  String _parentOf(String dirPath) {
    final index = dirPath.lastIndexOf('/');
    return index <= 0 ? '' : dirPath.substring(0, index);
  }

  /// 远程添加 WebDAV 源（lib.source.add，作用于目标节点）。
  Future<void> _addSourceDialog() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final user = TextEditingController();
    final pass = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加 WebDAV 网络源'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称（可选）')),
              TextField(
                controller: url,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'http://nas:5005/dav/媒体/',
                ),
              ),
              TextField(controller: user, decoration: const InputDecoration(labelText: '账号（可选）')),
              TextField(
                controller: pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可选）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('添加')),
        ],
      ),
    );
    if (added != true) return;
    try {
      final result = await widget.remote.addSource(
        kind: 'webdav',
        name: name.text.trim(),
        url: url.text.trim(),
        username: user.text.trim(),
        password: pass.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result['ok'] == true
            ? '已添加网络源'
            : '添加失败：${result['error'] ?? ''}'),
      ));
      await _loadSources();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('添加失败：$e')));
      }
    }
  }

  Future<void> _confirmRemove(SourceInfo source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('移除「\${source.name}」？'),
        content: const Text('仅从该节点移除内容源登记，不删除任何媒体文件。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('移除')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.remote.removeSource(sourceId: source.sourceId);
      if (!mounted) return;
      setState(() {
        _sources = null;
        _entries = null;
      });
      await _loadSources();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('移除失败：$e')));
      }
    }
  }
}
