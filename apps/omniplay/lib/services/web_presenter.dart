import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:node_core/node_core.dart';

/// 在线网页承载（优酷/爱奇艺/腾讯视频/B站等）：桌面节点用独立 WebView
/// 窗口全屏打开站点，控制端通过触控板/键盘（input.*）直接操作网页（R2 尽力而为）。
class DesktopWebPresenter implements WebPresenter {
  Webview? _webview;

  @override
  bool get isSupported => Platform.isMacOS || Platform.isWindows;

  @override
  Future<void> open(String url, {bool maximized = false, String? title}) async {
    try {
      _webview?.close();
    } on Object {
      // 旧窗口可能已关闭。
    }
    _webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: title ?? 'OmniPlay 在线影院',
        windowWidth: 1280,
        windowHeight: 800,
        titleBarHeight: 0,
        openMaximized: maximized,
      ),
    );
    _webview!.launch(url);
  }

  @override
  Future<void> close() async {
    _webview?.close();
    _webview = null;
  }
}
