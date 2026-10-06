# 插件开发手册（OmniPlay M1-α）

## 概念

主程序只提供**插件沙箱 + 节点能力注册表 + 商店 UI**，业务能力以插件形式存在。
任何 OmniPlay 功能都应是插件；核心代码是**消费者**，不是**提供者**。

## 目录结构

```
~/.omniplay/node/plugins/<plugin-id>/
├── plugin.yaml          # manifest（必需）
├── db.sqlite            # 插件私有存储（首次加载时存在占位；M2+ 实际建表）
└── user-scripts/        # 仅用户脚本引擎插件使用
```

## plugin.yaml schema

```yaml
id: org.omniplay.scripts.user.legacy  # 全局唯一，目录名等于 id
name: 用户脚本引擎（油猴兼容）
version: 0.1.0
minNodeVersion: 1                     # 可选
author: OmniPlay                      # 可选
description: |                        # 可选
  多行描述
dependencies:                         # 可选 v1.0+（占位字段，M2 启用）
  other.plugin: "^1.0.0"
```

YAML 极简解析器支持：扁平 key: value + 单层 map（dependencies: 子字段）；
避免引入 `yaml` 包。

## Dart 插件（节点能力型）

```dart
import 'package:node_core/src/plugin.dart';
import 'package:node_core/src/capability.dart';
import 'package:node_protocol/src/envelope.dart';

class MyPlugin implements OmniPlayPlugin {
  @override
  PluginManifest get manifest => PluginManifest(
    id: 'com.example.myplugin',
    name: '示例插件',
    version: '0.1.0',
  );

  @override
  Future<void> onLoad(PluginContext context) async {
    // 注册自定义 Capability；新消息族通过 CapabilityRegistry 自动路由。
    context.registry.register(MyCapability());

    // 私有存储（沙箱路径）：~/<dataDir>/plugins/<id>/
    final dbFile = File('${context.pluginDir}/db.sqlite');

    // 订阅：广播给所有已认证控制端的事件总线。
    context.broadcast('ready', {});
  }

  @override
  Future<void> onUnload() async {
    // 节点进程退出 / 插件卸载时调用；CapabilityRegistry 已自动撤销。
  }
}

class MyCapability implements NodeCapability {
  @override
  String get id => 'my.cap';
  @override
  Set<String> get handledTypes => {'my.command'};
  @override
  bool get supported => true;
  @override
  Future<bool> handle(Msg msg) async {
    if (msg.type == 'my.command') {
      // ... 处理 ...
      return true;
    }
    return false;
  }
  @override
  Map<String, Object?> status() => {'id': id, 'supported': supported};
}
```

Dart 插件通过本编进 `Node.registerBuiltIn(Plugin)` 注册（_buildOncePlugins 模式，
M2 升级为动态 `.so` 加载，无需改动 ABI）。

## 用户脚本插件（油猴兼容）

脚本引擎由内置插件 `org.omniplay.scripts.user.legacy` 提供，
**桌面 WebView 加载页面时自动注入 `document_start` 阶段**（Swift 注入通道，
M1-α 由 `UserScriptCapability.scriptsFor(url)` 提供匹配脚本）。

脚本源（GM v4 子集）：

```js
// ==UserScript==
// @name         iQiyi Boost (OmniPlay)
// @namespace    org.omniplay.scripts.user
// @version      0.1.0
// @match        https://www.iqiyi.com/*
// @run-at       document-start
// @description  去开屏广告、清晰度优先 1080p、键盘 P 暂停。
// ==/UserScript==
(function() { /* ... */ })();
```

**作用域严格限定**：脚本只作用于节点拉起的 WebView（M1-α 仅桌面）；
不影响真实浏览器、不跨设备泄露隐私。

## 安装与分发

- **本地安装**（开发态）：把插件目录拖到 `~/.omniplay/node/plugins/`；
- **M1-α UI**：Web 控制页"插件"标签（M2+）支持 `.oppack` 包（zip 含 yaml+lib+签名）
  上传安装；
- **M2+**：远程仓库 + Ed25519 签名校验；
- **M1-α 限制**：内置示例（`scripts.user.legacy` + `site.iqiyi`）由 `Node.registerBuiltIn`
  注入，不依赖商店；社区插件 v1.0 用 SHA-256 自校验。

## 调试

- 控制端连接节点后，订阅 `plugin.event`（`plugin.<id>.loaded/unloaded/installed` …）消息；
- 节点日志：插件 `context.broadcast(event, data)` 会经节点消息总线转发到控制端与
  Web UI 调试面板（M2+）。

## API 概览

| API | 说明 |
|---|---|
| `PluginContext.registry` | 注册节点能力（自动分发） |
| `PluginContext.pluginDir` | 沙箱路径（~/.omniplay/node/plugins/<id>/） |
| `PluginContext.broadcast` | 推消息到控制端 + Web UI 事件流 |
| `Node.plugins` | `PluginManager` 实例（scanAndLoad/installFromPath/uninstall/listPlugins） |
| `CapabilityRegistry.register/unregisterById` | 注册/卸载能力 |
| `UserScriptParser.parse` | 油猴元数据解析（独立工具函数，可单独 import） |

## 验证清单

- [ ] `manifest.id` 与目录名一致
- [ ] `onLoad` 注册的能力 `handledTypes` 唯一不冲突
- [ ] `onUnload` 释放外部资源（无残留 Capability）
- [ ] `Node.plugins.listPlugins()` 列出本插件
- [ ] `dart test` 全绿
- [ ] `dart analyze` 0 告警