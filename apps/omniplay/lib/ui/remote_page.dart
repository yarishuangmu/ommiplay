import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:node_core/node_core.dart';

import '../app_model.dart';
import '../services/mpv_adapter.dart';
import 'common.dart';
import 'remote_pad.dart';

/// Android 节点主页（C+P）：虚拟遥控器 + 本机播放（可被投）。
class RemoteHome extends StatefulWidget {
  const RemoteHome({super.key, required this.model});

  final AppModel model;

  @override
  State<RemoteHome> createState() => _RemoteHomeState();
}

class _RemoteHomeState extends State<RemoteHome> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('OmniPlay · ${widget.model.node.config.name}')),
      body: _tab == 0 ? _ControllerTab(model: widget.model) : _LocalPlayTab(model: widget.model),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.settings_remote), label: '遥控'),
          NavigationDestination(icon: Icon(Icons.smart_display_outlined), label: '本机播放'),
        ],
      ),
    );
  }
}

class _ControllerTab extends StatelessWidget {
  const _ControllerTab({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final peers = model.peers;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: const Text('手动添加节点'),
                subtitle: const Text('发现不到时输入对方 IP 和端口（三层兜底的最后一层）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _manualConnect(context),
              ),
            ),
            const SizedBox(height: 8),
            Text('在线播放器节点（${peers.length}）', style: Theme.of(context).textTheme.titleSmall),
            if (peers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('正在发现……确认两台设备在同一 Wi-Fi；若路由器开了 AP 隔离，用上方手动添加。'),
              ),
            for (final peer in peers)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.tv_outlined),
                  title: Text(peer.name),
                  subtitle: Text('${peer.host}:${peer.httpPort}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openRemote(context, peer),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _manualConnect(BuildContext context) async {
    final hostController = TextEditingController();
    final portController = TextEditingController(text: '47771');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动添加节点'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              decoration: const InputDecoration(labelText: 'IP 地址', hintText: '192.168.1.100'),
            ),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '端口'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('连接')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final host = hostController.text.trim();
    final port = int.tryParse(portController.text.trim()) ?? 0;
    if (host.isEmpty || port <= 0) return;
    await _openRemoteByName(context, host: host, port: port, name: host);
  }

  Future<void> _openRemote(BuildContext context, DiscoveredNode peer) =>
      _openRemoteByName(context, host: peer.host, port: peer.httpPort, name: peer.name);

  Future<void> _openRemoteByName(
    BuildContext context, {
    required String host,
    required int port,
    required String name,
  }) async {
    final remote = await connectWithPinFlow(context, model, host: host, port: port, name: name);
    if (remote == null || !context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RemoteControlScreen(model: model, remote: remote, targetName: name),
      ),
    );
  }
}

/// 遥控某个播放器节点（C3）。
class RemoteControlScreen extends StatelessWidget {
  const RemoteControlScreen({
    super.key,
    required this.model,
    required this.remote,
    required this.targetName,
  });

  final AppModel model;
  final PlayerRemote remote;
  final String targetName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('遥控：$targetName'),
        actions: [
          IconButton(
            tooltip: '断开',
            onPressed: () {
              model.disconnectActive();
              Navigator.pop(context);
            },
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: model,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: RemotePad(
            remote: remote,
            state: model.activeState,
            onBrowse: () => showBrowseSheet(context, remote),
          ),
        ),
      ),
    );
  }
}

/// 本机播放（P）：被其他节点投片时显示画面。
class _LocalPlayTab extends StatelessWidget {
  const _LocalPlayTab({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final player = model.localPlayer;
    final payload = model.localPayload;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => Column(
        children: [
          if (payload.controllerName != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text('受控于 ${payload.controllerName}'),
            ),
          Expanded(
            child: player is MpvPlayerAdapter
                ? Video(controller: player.videoController)
                : const Center(child: Text('播放内核未就绪')),
          ),
        ],
      ),
    );
  }
}
