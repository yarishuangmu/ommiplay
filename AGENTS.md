# AGENTS.md — OmniPlay 仓库协作说明

OmniPlay（家庭多端媒体中枢）：Flutter 双端节点应用 + 纯 Dart 节点核心 + Vue3 Web 控制页。
代码注释与文档以中文为主。

## 命令

- **Dart 包是 pub workspace**：根 `pubspec.yaml` 是唯一解析入口；装依赖用
  `cd <包目录> && dart pub add <pkg>`（或 flutter pub add），锁文件 `pubspec.lock` 在根目录且必须提交。
- `./tool/bootstrap.sh`：首次/依赖变更后执行（pub get + web_control 构建）。
- `./tool/test.sh`：`dart test packages` + `flutter analyze`（在 apps/omniplay）。
- 运行：`cd apps/omniplay && flutter run -d macos`（或 Android 设备 id）。
- 打包：`flutter build macos --debug`；`flutter build apk --split-per-abi --release`。
- web 页：`cd web_control && pnpm dev`（开发，代理到 127.0.0.1:47771）/ `pnpm build`（产物由节点托管）。

## 架构边界（改代码前必读 docs/architecture.md）

- **node_core 必须保持纯 Dart**：不许 import Flutter/bonsoir/path_provider。
  平台能力一律接口注入：播放内核实现 `PlayerAdapter`，发现实现 `DiscoveryChannel`
  （参考应用侧 `MpvPlayerAdapter`、`BonsoirDiscoveryAdapter`，测试用 `FakePlayerAdapter`）。
- **协议单一真相源**：消息类型/载荷改动先改 `packages/node_protocol`，同步 `docs/protocol.md`，
  再镜像到 `web_control/src/api.ts`；不要在业务代码里裸拼消息 type 字符串（用 `MsgTypes`）。
- **播放器是会话状态权威**：控制器只发指令收事件；不要把状态搬进控制器端做权威。
- **端口**：HTTP+WS 47771、UDP 信标 47770；端口 0 仅供测试。
- 进度等本地数据写 `NodeStore`（SQLite）；时间戳一律 HLC（`HlcClock`），不要用裸 DateTime 比较。

## 已知坑

- macOS 首启需允许"本地网络"权限，否则 mDNS 失效（UDP 信标与手动直连仍可用）。
- Android 模拟器与宿主间 mDNS/广播不通，联调用「手动添加节点」（宿主 IP 或 10.0.2.2）。
- media_kit 在 Android 必须 Release 模式验收性能；打包用 --split-per-abi。
- PIN 5 分钟过期且一次性；配对失败优先怀疑 PIN 过期。
- flutter test/dart test 前无需 build:types 之类的步骤（pub workspace 即解析即用）。

## 里程碑纪律

M0=双端闭环（已交付 M0-α）；M1=对等归集+NAS 无头节点；M2=Android TV；M3=音乐与在线；
M4=长尾平台（鸿蒙/Web 引擎/DLNA）；M5=阅读（最后）。范围变更先改需求分析/选型文档再动代码。
