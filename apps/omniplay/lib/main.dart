import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:node_core/node_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_model.dart';
import 'services/bonsoir_discovery.dart';
import 'services/keep_awake.dart';
import 'services/mpv_adapter.dart';
import 'ui/player_page.dart';
import 'ui/remote_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  if (Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(960, 620),
      title: 'OmniPlay',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final supportDir = await getApplicationSupportDirectory();
  final dataDir = p.join(supportDir.path, 'node');

  final node = Node(
    config: NodeConfig(
      name: _nodeName(),
      dataDir: dataDir,
      webRoot: _webRoot(),
    ),
    playerAdapterFactory: () => MpvPlayerAdapter(Player()),
  );
  await node.start();

  // mDNS 通道在 Flutter 侧（bonsoir 是插件），启动后并入 node_core 的发现合并器。
  final bonsoir = BonsoirDiscoveryAdapter(
    selfNodeId: node.nodeId,
    nodeName: node.config.name,
    httpPort: node.boundPort,
  );
  try {
    await bonsoir.start();
    node.discovery?.addChannel(bonsoir);
  } on Object {
    // mDNS 不可用（如模拟器/驱动问题）不影响 UDP 信标与手动直连兜底。
  }

  final keepAwake = KeepAwake();
  await keepAwake.start();

  final model = AppModel(node: node, myName: node.config.name);
  runApp(OmniPlayApp(model: model));
}

String _nodeName() {
  try {
    if (Platform.isMacOS) return Platform.localHostname;
    if (Platform.isAndroid) return 'Android 设备';
  } on Object {
    // 忽略，走默认名。
  }
  return 'OmniPlay 节点';
}

/// 开发期便利：若仓库里有 web_control 构建产物则一并托管（macOS 运行时）。
String? _webRoot() {
  if (!Platform.isMacOS) return null;
  final dist = Directory(p.normalize(p.join(Directory.current.path, '../../web_control/dist')));
  return dist.existsSync() ? dist.path : null;
}

class OmniPlayApp extends StatelessWidget {
  const OmniPlayApp({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniPlay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei'],
      ),
      home: Platform.isMacOS ? PlayerPage(model: model) : RemoteHome(model: model),
    );
  }
}
