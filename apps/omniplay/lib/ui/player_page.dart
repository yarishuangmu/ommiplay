import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:node_core/node_core.dart';

import '../app_model.dart';
import '../services/mpv_adapter.dart';
import 'common.dart';
import 'remote_pad.dart';

/// macOS 播放器节点页（C+P+L）：本机播放 + 配对 PIN + 媒体目录 + 遥控其他节点。
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: model,
        builder: (context, _) => Row(
          children: [
            Expanded(child: _PlayerColumn(model: model)),
            const VerticalDivider(width: 1),
            SizedBox(width: 320, child: _SidePanel(model: model)),
          ],
        ),
      ),
    );
  }
}

class _PlayerColumn extends StatelessWidget {
  const _PlayerColumn({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final player = model.localPlayer;
    final snapshot = model.localSnapshot;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Text(model.node.config.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 12),
              SelectableText(model.node.lanUrl, style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              if (snapshot.state != PlaybackStateName.idle)
                Text('${snapshot.state.name} · ${snapshot.title ?? ''}',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: player is MpvPlayerAdapter
              ? Video(controller: player.videoController)
              : const Center(child: Text('本节点未挂载播放内核')),
        ),
      ],
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final payload = model.localPayload;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _PinCard(model: model),
        const SizedBox(height: 12),
        _SourcesCard(model: model),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本机播放', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('状态：${payload.state.name} · 受控于 ${payload.controllerName ?? '无'}'),
                Text('内容源：${model.node.library.sources.length} 个目录'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _PeersCard(model: model),
      ],
    );
  }
}

class _PinCard extends StatefulWidget {
  const _PinCard({required this.model});

  final AppModel model;

  @override
  State<_PinCard> createState() => _PinCardState();
}

class _PinCardState extends State<_PinCard> {
  bool _showQr = false;
  String? _joinToken;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final pin = model.node.currentPin ?? model.node.newPin();
    final lanUri = Uri.parse(model.node.lanUrl);
    final joinToken = _showQr ? (_joinToken ??= model.node.newJoinToken()) : null;
    final qrData = joinToken == null
        ? ''
        : 'omniplay://join?host=${lanUri.host}&port=${lanUri.port}&t=$joinToken&name=${Uri.encodeComponent(model.node.config.name)}';
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('配对', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: _showQr ? '显示 PIN' : '显示扫码二维码',
                  onPressed: () => setState(() {
                    _showQr = !_showQr;
                    _joinToken = null;
                  }),
                  icon: Icon(_showQr ? Icons.pin_outlined : Icons.qr_code),
                ),
                IconButton(
                  tooltip: '重新生成',
                  onPressed: model.refreshPin,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (_showQr) ...[
              Center(child: QrImageView(data: qrData, size: 180, backgroundColor: Colors.white)),
              const SizedBox(height: 6),
              const Text('手机端「扫码配对」扫描此码，免输 PIN 加入'),
            ] else ...[
              Text(pin, style: Theme.of(context).textTheme.displaySmall?.copyWith(letterSpacing: 8)),
              Text('新设备（手机/Web 控制页）输入此 PIN 加入家庭', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourcesCard extends StatelessWidget {
  const _SourcesCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final sources = model.node.library.sources;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('内容源', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: '添加内容源',
                  onPressed: () => _showAddSheet(context),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (sources.isEmpty)
              const Text('还没有内容源，点 + 添加本地目录或 WebDAV 网络源',
                  style: TextStyle(color: Colors.grey)),
            for (final source in sources)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(source.kind == 'webdav'
                    ? Icons.cloud_outlined
                    : Icons.folder_outlined),
                title: Text(source.name),
                subtitle: Text(
                  source.kind == 'webdav' ? 'WebDAV · ${source.root}' : source.root,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '移除',
                  onPressed: () => model.removeSource(source.sourceId),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddSheet(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('本地目录'),
              subtitle: const Text('本机文件夹或已挂载的 SMB/NFS'),
              onTap: () => Navigator.pop(sheetContext, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('WebDAV 网络源'),
              subtitle: const Text('NAS / Alist 等网络存储'),
              onTap: () => Navigator.pop(sheetContext, 'webdav'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'folder') {
      final path = await getDirectoryPath();
      if (path != null) model.addMediaDir(path);
    } else if (choice == 'webdav') {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _WebdavSourceDialog(model: model),
      );
    }
  }
}

/// WebDAV 源添加表单（主机侧本地添加）。
class _WebdavSourceDialog extends StatefulWidget {
  const _WebdavSourceDialog({required this.model});

  final AppModel model;

  @override
  State<_WebdavSourceDialog> createState() => _WebdavSourceDialogState();
}

class _WebdavSourceDialogState extends State<_WebdavSourceDialog> {
  _WebdavSourceDialogState();

  final _name = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_url.text.trim().isEmpty) {
      setState(() => _error = '请填写 WebDAV 地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.addWebdavSource(
        url: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        name: _name.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '添加失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 WebDAV 网络源'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: '名称（可选）')),
            TextField(
              controller: _url,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'WebDAV 地址',
                hintText: 'http://nas:5005/dav/媒体/',
              ),
            ),
            TextField(controller: _user, decoration: const InputDecoration(labelText: '账号（可选）')),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码（可选）'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '验证中…' : '添加'),
        ),
      ],
    );
  }
}

class _PeersCard extends StatelessWidget {
  const _PeersCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final peers = model.peers;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('在线节点（${peers.length}）', style: Theme.of(context).textTheme.titleSmall),
            if (peers.isEmpty)
              const Text('正在发现其他设备……（也可在 Android 上手动输入本机地址）',
                  style: TextStyle(color: Colors.grey)),
            for (final peer in peers)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices_other),
                title: Text(peer.name),
                subtitle: Text('${peer.host}:${peer.httpPort}'),
                trailing: FilledButton.tonal(
                  onPressed: () => _controlPeer(context, peer),
                  child: const Text('控制'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _controlPeer(BuildContext context, DiscoveredNode peer) async {
    final remote = await connectWithPinFlow(
      context,
      model,
      host: peer.host,
      port: peer.httpPort,
      name: peer.name,
    );
    if (remote == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: model,
            builder: (context, _) => SizedBox(
              width: 420,
              child: RemotePad(
                remote: remote,
                state: model.activeState,
                onBrowse: () => showBrowseSheet(dialogContext, remote),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
