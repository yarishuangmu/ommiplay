# 能力正交化与全局架构分析（M0-γ 设计）

> 输入：用户需求 ①节点应用以**后台服务+菜单托盘**形态存在（不要独立任务栏窗口）；
> ②能力**正交化**便于维护（文件/网址/鼠标触控板/游戏键盘各自独立）；③新增潜在需求：
> **手机仿真游戏手柄 → 电脑打游戏**（含未来游戏模拟器场景）、图书馆功能。

## 1. 托盘化（Tray-first）

| 平台 | 形态 | 实现 |
|---|---|---|
| macOS | **菜单栏托盘为主**，无 Dock 图标（LSUIElement）；主窗口降级为"按需面板"：关闭窗口=隐藏（应用常驻），托盘左键呼出窗口、右键菜单（显示面板/播放暂停/配对 PIN/退出） | Info.plist `LSUIElement`；window_manager `setPreventClose` + 关闭→hide；tray_manager `setContextMenu`（nativeapi `Menu.create`/`addItem`，点击按 `label` 识别） |
| Android | **前台服务通知即托盘**（已实现 NodeService）；常驻通知可扩展播放控制按钮（M2） | 已交付，本轮无改动；启动器图标保留（入口必需） |

原则：节点 = 常驻服务；UI = 服务的一个视图，关掉视图服务不死。

## 2. 能力正交化（NodeCapability 注册表）

现状问题：`NodeServer._onData` 是巨型 switch，新增能力（手柄/模拟器/图书馆）都要改核心路由。

目标形态：**能力 = 自注册模块**，核心路由只做"鉴权 → 查注册表 → 分发"。

```
NodeCapability {
  id            // 'gamepad' / 'web' / 'pointer_input' / 'library' / 'reader'(预留) / 'emulator'(预留)
  handledTypes  // 该能力拥有的消息类型集合（单一真相源）
  supported     // 平台/角色裁剪（无键鼠权能的移动端 = false）
  handle(msg)   // 处理并返回是否消费
}
```

- **已正交的平台桥**（此前已按接口注入，本轮归入注册表）：`PlayerAdapter`（播放内核）、
  `DiscoveryChannel`（发现通道）、`SystemControl`、`InputController`（键鼠）、`WebPresenter`、
  `ContentSource`（文件/网络源）、新增 `GamepadBridge`。
- **消息族归属**：`player.*`（播放会话）、`lib.*`（内容源）为会话核心能力，仍在核心路由
  （与 WS peer 状态强耦合，强行拆出反增复杂度）；`web.*`、`input.*`、`node.cmd.*`、新能力全部
  走注册表——**新能力零改动接入核心**。
- 预留插槽：`reader.*`（图书馆/阅读，M5）、`emulator.*`（游戏模拟器启动与管理，M2+）。

## 3. 游戏手柄仿真——可行性全局分析

**目标**：手机当手柄 → 桌面电脑打游戏 / 玩模拟器。

| 路线 | 原理 | 可行性 |
|---|---|---|
| A. 键鼠映射（本轮） | 手机手柄 UI → `input.gamepad` → 桌面按 **Profile 映射为 CGEvent 键鼠**（模拟键盘按下/抬起、鼠标视角） | ✅ 立即可行，复用现有 CGEvent 通道。**对模拟器场景是完美解**（RetroArch 等模拟器本来就吃键盘输入）；对普通 PC 游戏，绝大多数支持自定义键盘键位 |
| B. 真虚拟 HID 手柄 | DriverKit dext 创建虚拟游戏手柄设备 | ⚠️ macOS 需 DriverKit + 专属 entitlement + 公证，成本高；旧方案 kext（foohid）已废弃。**列为远期可选项**，接口已按 Bridge 抽象预留 |
| C. 系统级手柄协议（Steam/DInput） | 依赖第三方驱动生态 | ❌ 不自建 |

**分层设计（正交三段）**：

```
手机手柄 UI ──input.gamepad{button|axis}──▶ GamepadCapability（node_core，纯 Dart）
                                              └─ GamepadBridge（平台注入）
                                                   └─ KeyboardMappedGamepadBridge
                                                        + GamepadProfile（纯 Dart，可单测）
                                                        : buttons→按键, 左摇杆→方向键组(hold), 右摇杆→鼠标视角
```

- **GamepadProfile**：映射方案即数据。内置 `snes`（左摇杆=方向键、a=x/b=z/x=s/y=a、
  start=enter——RetroArch 类模拟器开箱即用）与 `wasd`（左摇杆=WASD、a=space、右摇杆=鼠标视角——
  通用 PC 游戏）。后续可加 `xinput`（真 HID 路线 B 时复用同一 profile 结构）。
- **摇杆语义**：axis 事件带死区（0.35），越界=按下方向键、回中=抬起——桥内维护按住状态，
  UI 只报位置，不报按键。
- **权限**：与键鼠控制同源（macOS 辅助功能授权一次）。

## 4. 实施清单（本轮）

1. node_core：`NodeCapability` 注册表 + 核心路由改造 + `GamepadCapability`/`GamepadBridge`/
   `GamepadProfile`（snes/wasd）+ `InputController.keyDown/keyUp`（按住语义）
2. macOS：LSUIElement + 托盘菜单（显示面板/播放暂停/配对 PIN/退出）+ 关闭即隐藏
3. Android：手柄 UI 标签页（ABXY/十字键/双摇杆/LR/Start）
4. 测试：注册表分发、手柄 Profile 映射（按键序列/摇杆死区按住状态）、E2E 追加 gamepad 项
5. 重建双端 + 真机/模拟器部署验证

## 5. 后续路线图（能力插槽）

| 能力 | 消息族预留 | 里程碑 |
|---|---|---|
| 图书馆/阅读（reader） | `reader.*` | M5 |
| 游戏模拟器（启动/管理模拟器进程 + 手柄叠加层） | `emulator.*`（复用 input.gamepad） | M2+ 评估 |
| 真虚拟 HID 手柄（DriverKit） | 复用 input.gamepad，仅换 Bridge | 远期可选 |
| Android 通知播放控制按钮 | — | M2 |
