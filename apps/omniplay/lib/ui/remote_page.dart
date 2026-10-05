import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('本机配对 PIN', style: Theme.of(context).textTheme.titleSmall),
                        const Spacer(),
                        IconButton(
                          tooltip: '重新生成',
                          onPressed: model.refreshPin,
                          icon: const Icon(Icons.refresh, size: 20),
                        ),
                      ],
                    ),
                    Text(
                      model.node.currentPin ?? model.node.newPin(),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 8),
                    ),
                    const Text('Mac 等桌面节点凭此 PIN 配对进本机', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('扫码配对'),
                subtitle: const Text('扫描节点屏幕上的二维码，免输 PIN'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _scanPair(context),
              ),
            ),
            const SizedBox(height: 8),
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

  Future<void> _scanPair(BuildContext context) async {
    final joined = await Navigator.push<({String host, int port, String token})>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPairPage()),
    );
    if (joined == null || !context.mounted) return;
    final remote = await connectWithTokenFlow(
      context,
      model,
      host: joined.host,
      port: joined.port,
      token: joined.token,
    );
    if (remote == null || !context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RemoteControlScreen(model: model, remote: remote, targetName: '扫码节点'),
      ),
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

/// 遥控某个播放器节点：遥控盘（语义按键）/ 触控板（电脑控制）/ 键盘 三个模式。
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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('遥控：$targetName'),
          actions: [
            IconButton(
              tooltip: '在线影院（优酷/爱奇艺/腾讯…）',
              onPressed: () => _openSitesSheet(context),
              icon: const Icon(Icons.ondemand_video),
            ),
            IconButton(
              tooltip: '电源/系统',
              onPressed: () => _openPowerSheet(context),
              icon: const Icon(Icons.power_settings_new),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.dialpad), text: '遥控盘'),
            Tab(icon: Icon(Icons.touch_app), text: '触控板'),
            Tab(icon: Icon(Icons.keyboard_outlined), text: '键盘'),
          ]),
        ),
        body: ListenableBuilder(
          listenable: model,
          builder: (context, _) => TabBarView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: RemotePad(
                    remote: remote,
                    state: model.activeState,
                    onBrowse: () => showBrowseSheet(context, remote),
                  ),
                ),
              ),
              _TouchpadTab(remote: remote),
              _KeyboardTab(remote: remote),
            ],
          ),
        ),
      ),
    );
  }

  /// 在线影院（D1 在线流媒体，R2 尽力而为）：桌面节点内置 WebView 打开站点，
  /// 再用触控板/键盘直接操作网页。
  Future<void> _openSitesSheet(BuildContext context) async {
    final sites = {
      '优酷': 'https://www.youku.com/',
      '爱奇艺': 'https://www.iqiyi.com/',
      '腾讯视频': 'https://v.qq.com/',
      '哔哩哔哩': 'https://www.bilibili.com/',
    };
    final custom = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('在「$targetName」打开网页播放', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final entry in sites.entries)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(entry.key),
                subtitle: Text(entry.value),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  try {
                    await remote.webOpen(entry.value, title: entry.key);
                  } on Object catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('打开失败：$e')));
                    }
                  }
                },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: custom,
                      decoration: const InputDecoration(labelText: '自定义网址', hintText: 'https://…'),
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      final url = custom.text.trim();
                      if (url.isEmpty) return;
                      Navigator.pop(sheetContext);
                      try {
                        await remote.webOpen(url, title: '网页');
                      } on Object catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('打开失败：$e')));
                        }
                      }
                    },
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// 电源/系统菜单（重启控制）。
  Future<void> _openPowerSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('重播当前媒体'),
              onTap: () {
                Navigator.pop(sheetContext);
                remote.sendKey('restart');
              },
            ),
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('全屏切换'),
              onTap: () {
                Navigator.pop(sheetContext);
                remote.sendKey('fullscreen');
              },
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('重启节点应用'),
              onTap: () {
                Navigator.pop(sheetContext);
                remote.restartApp();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重启节点系统'),
              subtitle: const Text('仅桌面节点支持，需系统授权'),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  await remote.rebootSystem();
                } on Object catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('让节点系统睡眠'),
              onTap: () {
                Navigator.pop(sheetContext);
                remote.sleepSystem();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 触控板（仿真触控板）：滑动=移动鼠标，轻点=左键，双击=双击，右侧滚动条。
class _TouchpadTab extends StatelessWidget {
  const _TouchpadTab({required this.remote});

  final PlayerRemote remote;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) =>
                        remote.mouseMove(dx: d.delta.dx, dy: d.delta.dy),
                    onTap: () => remote.mouseClick(),
                    onDoubleTap: () => remote.mouseClick(doubleClick: true),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: const Text('触控板\n滑动=移动 · 轻点=左键 · 双击=双击',
                          textAlign: TextAlign.center),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => remote.mouseScroll(dx: 0, dy: d.delta.dy),
                  child: Container(
                    width: 56,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: const RotatedBox(
                      quarterTurns: 1,
                      child: Text('滚 动'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: () => remote.mouseClick(),
                child: const Text('左键'),
              ),
              const SizedBox(width: 16),
              FilledButton.tonal(
                onPressed: () => remote.mouseClick(button: 'right'),
                child: const Text('右键'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 键盘模式：输入文字 + 常用按键直通（网页里 F=全屏、空格=播放…）。
class _KeyboardTab extends StatefulWidget {
  const _KeyboardTab({required this.remote});

  final PlayerRemote remote;

  @override
  State<_KeyboardTab> createState() => _KeyboardTabState();
}

class _KeyboardTabState extends State<_KeyboardTab> {
  final _controller = TextEditingController();

  static const _keys = [
    'space', 'enter', 'esc', 'tab',
    'up', 'down', 'left', 'right',
    'f', 'p', 'm', 's',
    'volumeUp', 'volumeDown', 'mute',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: '输入文字（直接键入到节点）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final text = _controller.text;
                  if (text.isNotEmpty) {
                    widget.remote.inputText(text);
                    _controller.clear();
                  }
                },
                child: const Text('键入'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final key in _keys)
                OutlinedButton(
                  onPressed: () => widget.remote.keyPress(key),
                  child: Text(key),
                ),
            ],
          ),
          const Spacer(),
          const Text('提示：网页里 F=全屏、空格=播放/暂停、←→=快进退',
              style: TextStyle(color: Colors.grey)),
        ],
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

/// 扫码配对页（M0-β）：解析节点屏幕上的 omniplay://join 二维码。
class ScanPairPage extends StatelessWidget {
  const ScanPairPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描节点二维码')),
      body: MobileScanner(
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            final code = barcode.rawValue;
            if (code == null || !code.startsWith('omniplay://join')) continue;
            final uri = Uri.tryParse(code);
            if (uri == null) continue;
            final host = uri.queryParameters['host'];
            final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? 0;
            final token = uri.queryParameters['t'];
            if (host == null || port <= 0 || token == null) continue;
            Navigator.pop(context, (host: host, port: port, token: token));
            return;
          }
        },
      ),
    );
  }
}
