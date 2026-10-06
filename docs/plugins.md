# 插件化架构与在线影院（M1-α 设计）

> 输入：用户需求
> ① 在线影院需要支持类似 Greasy/Tampermonkey 的**站点优化脚本**；
> ② 各项能力（在线影院、刮削、字幕、源解析…）应**作为独立插件**分发；
> ③ 插件独立安装，类似"插件商店"；
> ④ **不要操控用户的系统浏览器**——只能作用于节点内 WebView，避免破坏用户隐私与体验。

## 1. 核心决策：能力即插件

**主程序 = 插件沙箱 + 商店 UI + 平台桥；不内置业务能力。**

| 当前实现 | 插件化后 |
|---|---|
| `web.open` + `web.close`（直接打开 URL） | 业务功能（如"爱奇艺播放"）作为插件，节点只提供 `web.open` 平台能力 |
| `lib.source.add` 硬编 folder/webdav 两种 | `ContentSource` 类型本身由插件注册，类型名随意（如"追番"插件的 `bangumi` 源） |
| 在线影院是 Mac 节点内置 `DesktopWebPresenter` | WebView 本身是节点 API 业务功能，桌面 WebView 浏览器可作为插件独立升级 |

## 2. 插件模型

```dart
abstract class OmniPlayPlugin {
  String get id;          // 'com.omniplay.iqiyi' / 'org.user.scripts' 等
  String get name;        // '爱奇艺优化' / '用户脚本引擎'
  String get version;
  int get minNodeVersion;

  /// 插件激活时注册的能力列表；卸载时自动撤销
  void register(CapabilityRegistry registry, PluginContext ctx);
}
```

`PluginContext` 提供：HTTP 客户端、SQLite 句柄、消息总线、用户脚本引擎、文件 IO
（沙箱路径 `~/.node-apli/plugins/<id>/`）。

## 3. 商店与安装

- **分发**：每个插件一个目录，含 `plugin.yaml`（manifest）、`lib/<plugin>.dylib`（Dart
  内核编译产物）或 `web/<id>.vue`（仅 Web 资源）。沙箱中运行，不共享主程序命名空间。
- **安装方式**：
  - **本地安装**：把插件目录拖入 `~/.node-apli/plugins/`（开发模式）；
  - **远程仓库**：节点连同节点同步请求（v2 路线，M1+）；
  - **离线包**：导出 `.oppack`（zip 含 yaml+lib+签名），从 Web UI 上传安装（M1-α）。
- **签名**（v2）：M1-α 暂用 SHA-256 自校验；M2 起 Ed25519 + 仓库签名链。
- **Web UI（macOS）**：新增"插件"标签页（NodeCapability 注册表查询 + 安装/启用/禁用/卸载/查看）。

## 4. 用户脚本引擎（油猴风格）

插件 `org.omniplay.scripts.user.legacy`：
- 注册能力 `scripts.user`，消息族 `script.install/list/remove/enable/disable/eval`；
- 桌面 WebView 加载页面后**注入 document_start** 阶段，运行启用脚本（匹配 `@match`）；
- 脚本持久化在插件沙箱 SQLite（按 `@name` + `@version` + `@match` 摘要）；
- 内置：`@match @run-at document-start` 元数据解析器（GreaseMonkey v4 子集）；外部脚本
  可通过 `eval/runInPage` 在节点进程求值（受限沙箱）；
- **作用域严格限定在 WebView 内打开的站点**（来自 `web.open`/用户手动输入的 URL）；不影响
  用户系统浏览器，也不影响节点内其他上下文。

## 5. 桌面 WebView 与"集成浏览器"

- **不再操控用户系统浏览器**。节点自带的 WebView（路线 A 已实现 `desktop_webview_window`）
  是 OmniPlay 的"集成浏览器"：节点拉起、WebView 隔离、用户主动 URL、由用户脚本引擎注入；
- 插件可在该 WebView 之上做站点特化（爱奇艺自动跳转清晰度、腾讯跳过广告、B 站关弹幕、…）；
- 移动端是否在 APK 内嵌一个迷你 WebView（路线 B）放后续评估——**不"控制"用户 Chrome 即可，
  我们只在自己拉起的 WebView 内注入**。

## 6. 实施清单（M1-α 本轮）

1. **node_core**：`Plugin`/`PluginContext`/`PluginManager`；卸载钩子；`PluginManifest`
   YAML schema + 解析器；沙箱 SQLite 注册表；插件消息族（`script.*`）。
2. **Mac 应用**：插件目录扫描（启动时 + 运行时热加载）；安装/卸载 HTTP API；WebView 加载
   后调用脚本引擎（document_start 注入）。
3. **Web 控制页**：新增"插件"标签页（列表/安装/启用/禁用/查看源码/打开脚本页）。
4. **示例插件**（演示而非纯开发文档）：
   - `scripts.user.legacy`：用户脚本引擎（引擎本身是插件，内置元数据解析 + 注入通道）；
   - `site.iqiyi`：爱奇艺优化（清晰度跳转、去广告、键盘快捷键）—— 通过用户脚本承载
     （实际就是个 JS 文件）；放到 `user-scripts/` 目录，UI 一键安装/启用。
5. **文档**：
   - `README` 加"插件"章节；
   - `docs/plugin-dev.md`：插件作者手册（manifest schema、API、能力注册、构建分发）。
6. **测试**：插件加载/卸载、用户脚本元数据、源去重；构建 WebView 注入通道 mock 测试。

## 7. 后续路线

| 里程碑 | 内容 |
|---|---|
| M1-α（本轮） | 插件模型 + 商店 UI + 用户脚本引擎 + 示例 |
| M1-β | 远程仓库、签名链、HA 分发插件元数据 |
| M1-γ | 各领域插件化（刮削、字幕、内容源、模拟器） |
| M2 | Android TV 端按插件安装画布；移动端嵌入式迷你 WebView 评估 |