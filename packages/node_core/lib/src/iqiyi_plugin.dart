import 'dart:async';

import 'package:node_core/src/plugin.dart';

/// 示例：爱奇艺"节点优化"插件——自动把清晰度跳到 1080p，跳过开屏广告（社区已成熟的
/// GreaseMonkey 脚本可直接打包）。本类暴露 manifest，桌面端 WebView 加载 iqiyi 时，
/// 由 WebView 注入通道（UserScriptEngine）调用 kIqiyiUserScript 执行 JS 代码。
class IqiyiBoostPlugin implements OmniPlayPlugin {
  @override
  PluginManifest get manifest => PluginManifest(
        id: 'site.iqiyi',
        name: '爱奇艺节点优化',
        version: '0.1.0',
        author: 'OmniPlay',
        description: 'WebView 加载爱奇艺时自动注入：去开屏广告、清晰度优先 1080p、键盘 P 暂停。',
      );

  @override
  Future<void> onLoad(PluginContext context) async {
    // 该插件的实际脚本由桌面 Swift 端在 WebView 加载时注入；Node 端登记 manifest 即可。
  }

  @override
  Future<void> onUnload() async {}
}

/// 示例用户脚本代码（爱奇艺去广告 + 优先 1080p）：打包在插件目录里被 Swift 注入。
/// 实际部署时由社区脚本替代；此为最小演示。
const String kIqiyiUserScript = r'''
// ==UserScript==
// @name         iQiyi Boost (OmniPlay)
// @namespace    org.omniplay.scripts.user
// @version      0.1.0
// @match        https://www.iqiyi.com/*
// @run-at       document-start
// @description  去开屏广告；播放器优先 1080p；按 P 暂停。
// ==/UserScript==
(function() {
  'use strict';
  // 1) 跳过开屏（splash 元素由 iqiyi 渲染时动态注入——示例仅在 DOMReady 后移除 flash 层）。
  document.addEventListener('DOMContentLoaded', function() {
    var splash = document.querySelector('[class*="splash"]');
    if (splash) splash.remove();
  });
  // 2) 清晰度优先 1080p。
  var timer = setInterval(function() {
    var high = document.querySelector('[data-quality="1080p"]') ||
               document.querySelector('[title*="1080"]');
    if (high) { high.click(); clearInterval(timer); }
  }, 1000);
  setTimeout(function() { clearInterval(timer); }, 60000);
  // 3) 键盘快捷键：P 切换暂停。
  document.addEventListener('keydown', function(e) {
    if (e.key === 'p' || e.key === 'P') {
      var v = document.querySelector('video');
      if (v) { v.paused ? v.play() : v.pause(); }
    }
  });
})();
''';