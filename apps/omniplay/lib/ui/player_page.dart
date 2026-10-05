import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
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
        _MediaDirsCard(model: model),
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

class _PinCard extends StatelessWidget {
  const _PinCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final pin = model.node.currentPin ?? model.node.newPin();
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('配对 PIN', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: '换一个 PIN',
                  onPressed: model.refreshPin,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            Text(pin, style: Theme.of(context).textTheme.displaySmall?.copyWith(letterSpacing: 8)),
            Text('新设备（手机/Web 控制页）输入此 PIN 加入家庭', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _MediaDirsCard extends StatelessWidget {
  const _MediaDirsCard({required this.model});

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
                Text('媒体目录（内容源）', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: '添加目录',
                  onPressed: () async {
                    final path = await getDirectoryPath();
                    if (path != null) model.addMediaDir(path);
                  },
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (sources.isEmpty)
              const Text('还没有内容源，点 + 选择文件夹（如 NAS 挂载点）', style: TextStyle(color: Colors.grey)),
            for (final source in sources)
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined),
                title: Text(source.name),
                subtitle: Text(source.root, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
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
