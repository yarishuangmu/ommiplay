import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:node_core/node_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// tray_manager 0.7.0 主库漏导出自身实现（TrayManager/TrayListener），直接引 src。
// ignore: implementation_imports
import 'package:tray_manager/src/tray_listener.dart';
// ignore: implementation_imports
import 'package:tray_manager/src/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_model.dart';
import 'services/bonsoir_discovery.dart';
import 'services/keep_awake.dart';
import 'services/mac_system_control.dart';
import 'services/mpv_adapter.dart';
import 'services/web_presenter.dart';
import 'ui/player_page.dart';
import 'ui/remote_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final isMac = Platform.isMacOS;

  if (isMac) {
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

  // 平台能力注入（node_core 保持纯 Dart）。
  final SystemControl systemControl = isMac ? MacSystemControl() : AndroidSystemControl();
  final InputController? inputController = isMac ? MacInputController() : null;
  final WebPresenter? webPresenter = isMac ? DesktopWebPresenter() : null;

  final node = Node(
    config: NodeConfig(
      name: _nodeName(),
      dataDir: dataDir,
      webRoot: _webRoot(),
    ),
    playerAdapterFactory: () => MpvPlayerAdapter(Player()),
    systemControl: systemControl,
    webPresenter: webPresenter,
    inputController: inputController,
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
  if (Platform.isAndroid) {
    await keepAwake.startNodeService(); // 前台服务保活节点（M0-β）
  }

  if (isMac) {
    _setupTray();
  }

  final model = AppModel(node: node, myName: node.config.name);
  runApp(OmniPlayApp(model: model));
}

/// 系统托盘（macOS，M0-β）：点击托盘图标调回主窗口。
void _setupTray() {
  // ignore: deprecated_member_use
  final tray = TrayManager.instance;
  tray.setIcon('assets/tray_icon.png');
  tray.addListener(_TrayHandler());
}

// ignore: deprecated_member_use
class _TrayHandler with TrayListener {
  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }
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
