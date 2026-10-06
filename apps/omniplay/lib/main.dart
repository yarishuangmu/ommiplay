// tray_manager 0.7.0 主库漏导出自身实现且标记 deprecated，托盘能力经 src 路径使用（包缺陷，见 docs/development.md）。
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:node_core/node_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// tray_manager 0.7.0 主库漏导出自身实现（Menu/TrayManager/TrayListener），直接引 src。
import 'package:tray_manager/src/menu.dart' as t; // ignore: implementation_imports
import 'package:tray_manager/src/tray_listener.dart' as t; // ignore: implementation_imports
import 'package:tray_manager/src/tray_manager.dart' as t; // ignore: implementation_imports
import 'package:window_manager/window_manager.dart';

import 'app_model.dart';
import 'services/bonsoir_discovery.dart';
import 'services/gamepad_bridge.dart';
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
    // 托盘常驻（M0-γ）：关闭窗口=隐藏面板，服务不死。
    await windowManager.setPreventClose(true);
    windowManager.addListener(_WindowListener());
  }

  final supportDir = await getApplicationSupportDirectory();
  final dataDir = p.join(supportDir.path, 'node');

  // 平台能力注入（node_core 保持纯 Dart）。
  final SystemControl systemControl = isMac ? MacSystemControl() : AndroidSystemControl();
  final InputController? inputController = isMac ? MacInputController() : null;
  final WebPresenter? webPresenter = isMac ? DesktopWebPresenter() : null;
  // 手柄桥：键鼠映射（模拟器/支持键位的 PC 游戏）；真 HID（DriverKit）为远期路线 B。
  final GamepadBridge? gamepadBridge =
      (isMac && inputController != null) ? KeyboardGamepadBridge(inputController) : null;

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
    gamepadBridge: gamepadBridge,
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
  _sharedModel = model;
  runApp(OmniPlayApp(model: model));
}

/// 共享模型（托盘菜单回调使用，main 中赋值）。
AppModel? _sharedModel;

/// 系统托盘（macOS，M0-γ）：左键呼出主面板；右键菜单=面板/播放暂停/PIN/退出。
void _setupTray() {
  final tray = t.TrayManager.instance;
  tray.setIcon('assets/tray_icon.png');
  tray.addListener(_TrayHandler());

  void showPanel() {
    windowManager.show();
    windowManager.focus();
  }

  tray.setContextMenu(
    t.Menu(
      items: [
        t.MenuItem(label: '显示主面板', onClick: (_) => showPanel()),
        t.MenuItem(
          label: '播放 / 暂停',
          onClick: (_) {
            final player = _sharedModel?.localPlayer;
            final snapshot = _sharedModel?.localSnapshot;
            if (player != null && snapshot != null) {
              snapshot.state == PlaybackStateName.playing
                  ? player.pause()
                  : player.play();
            }
          },
        ),
        t.MenuItem(
          label: '显示配对 PIN',
          onClick: (_) {
            showPanel();
            _sharedModel?.refreshPin();
          },
        ),
        t.MenuItem.separator(),
        t.MenuItem(label: '退出 OmniPlay', onClick: (_) => windowManager.destroy()),
      ],
    ),
  );
}

class _TrayHandler with t.TrayListener {
  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }
}

class _WindowListener with WindowListener {
  @override
  void onWindowClose() async {
    // 托盘常驻：窗口关闭按钮=隐藏面板。
    await windowManager.hide();
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
