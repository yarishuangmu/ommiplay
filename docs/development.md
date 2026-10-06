# 开发文档

## 环境要求

| 工具 | 版本 | 说明 |
|---|---|---|
| Flutter | ≥3.47 stable | 需启用 macOS desktop 与 Android 工具链 |
| Dart | ≥3.13 | pub workspace（根 pubspec.yaml 统一解析） |
| CocoaPods | ≥1.15 | macOS 原生插件构建（media_kit） |
| Node / pnpm | ≥20 / ≥9 | 仅 web_control 构建用 |

一次性补齐（本机已完成）：

```bash
brew install cocoapods
# Android cmdline-tools 缺失时：
curl -o /tmp/ct.zip https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip
unzip /tmp/ct.zip -d ~/Library/Android/sdk/cmdline-tools/latest.tmp
mv ~/Library/Android/sdk/cmdline-tools/latest.tmp/cmdline-tools ~/Library/Android/sdk/cmdline-tools/latest
yes | flutter doctor --android-licenses
```

## 常用命令

| 命令 | 说明 |
|---|---|
| `./tool/bootstrap.sh` | 首次/依赖变更后：dart pub get + web_control 构建 |
| `./tool/test.sh` | dart test（packages）+ flutter analyze |
| `dart analyze packages` | 核心包静态检查 |
| `cd apps/omniplay && flutter run -d macos` | 运行 macOS 节点 |
| `cd apps/omniplay && flutter run -d <id>` | 运行 Android 节点（`flutter devices` 查 id） |
| `flutter build macos --debug` / `flutter build apk --split-per-abi` | 打包 |

## 双端联调

1. **两台真机同一 Wi-Fi**：正常路径是 mDNS/UDP 信标自动发现（上线 10 秒内）。
2. **Android 模拟器 ↔ Mac**：模拟器网络是 NAT，mDNS/广播通常不通——用「手动添加节点」，
   IP 填 Mac 的局域网 IP（模拟器访问宿主机也可用 `10.0.2.2`），端口 47771。
3. **路由器 AP 隔离**：三层兜底的最后一层（手动 IP + PIN）始终可用，这正是 A1 的设计。
4. 节点服务端口：HTTP+WS `47771/tcp`、UDP 信标 `47770/udp`（可在 NodeConfig 改）。

### 常见问题

- **macOS 首启弹"本地网络"权限框**：必须允许，否则 mDNS 失效（UDP 信标仍可用）。
- **macOS UDP 广播不可用**：Dart 未暴露 SO_BROADCAST，向 255.255.255.255 发送会异步 EACCES
  （错误打在 socket 的 onError 上）。信标实现已用**组播 239.255.77.88** 作主通道、
  广播从专用短命 socket 尽力而为；不要在主监听 socket 上直接发广播。
- **Windows 防火墙**（未来平台）：首启需放行 47771 入站。
- **端口被占**：日志会抛 SocketException；改 NodeConfig 端口或释放占用。
- **PIN 一直无效**：PIN 5 分钟过期且一次性，用播放器页"刷新"重新生成。
- **Android 上收不到信标**：已实现 MulticastLock（MainActivity），若仍失败属机型限制，走手动直连。
- **Android 节点保活**：M0-β 起有前台服务（NodeService，常驻通知），应用启动即拉起；
  MIUI 锁屏仍可能限制网络（Doze），配对/遥控时保持亮屏效果最佳。可在电池策略中设为"无限制"。
- **macOS 键鼠控制授权**：首次使用触控板/键盘功能需在"系统设置 → 隐私与安全性 → 辅助功能"
  授权 OmniPlay（CGEvent 事件投递要求），否则事件静默丢失。
- **tray_manager 0.7.0**：主库漏导出自身实现且标 deprecated，直接引 `package:tray_manager/src/…`
  （main.dart 已文件级 ignore）。声明式 `Menu(items:[MenuItem(label:, onClick:)])` 可用。
- **macOS 托盘常驻**：Info.plist `LSUIElement=true`（无 Dock 图标）+ 窗口关闭=隐藏；
  退出走托盘菜单"退出 OmniPlay"。
- **手柄仿真**：手机"手柄"标签页 → `input.gamepad` → 桌面 KeyboardMappedGamepadBridge
  按 Profile（snes=模拟器布局/wasd=PC游戏）映射键鼠；需辅助功能授权。真虚拟 HID（DriverKit）
  为远期路线 B，协议不变只换桥。
- **验证工具**：`cd packages/node_core && dart run tool/probe_node.dart <host> [port]`
  可对任意节点做 HTTP/信标/WS 三层探测（WS 用一次性临时身份，被拒=在线且未配对）；
  `dart run tool/link_check.dart <host>` 用本机节点身份验证配对互信与控制面；
  `dart run tool/e2e_check.dart <host> [port] --pin <PIN> --videoDir <目录> --web <url>`
  跑全链路验收（配对→加源→浏览→投片→播放推进→语义按键→在线影院）。
  节点提供回环专用的 `GET /api/pin`（仅 127.0.0.1，返回当前配对 PIN）供自动化脚本取码；
  Web 控制页已含遥控盘/触控板/键盘/在线影院/电源菜单全功能。
- **网络源（WebDAV）**：Mac 端「内容源」卡片或手机浏览面板（右上 +）添加，填 `http://nas:5005/dav/媒体/`
  形式地址+账号密码；凭据明文存本节点 SQLite（v1 家庭威胁模型），播放流经源节点代理转发（凭据不下发给播放器）。
  SMB 建议继续用 OS 挂载当本地目录。

## 打包发布（M0）

- **macOS**：`flutter build macos --release` → `apps/omniplay/build/macos/Build/Products/Release/omniplay.app`（当前 entitlements 已关闭 App Sandbox，仅限家庭自用，勿上架）。
- **Android**：`flutter build apk --split-per-abi --release` → `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（split-per-abi 显著减小体积，media_kit 官方建议）。
- Web 控制页：`cd web_control && pnpm build` → `dist/`；macOS 运行时若在仓库内会自动托管该目录（apps/omniplay/lib/main.dart 的 `_webRoot()`），APK 不托管 Web 页（手机节点用原生 UI）。

## 工程约定

- **pub workspace**：根 `pubspec.yaml` 列出全部 Dart 包，锁文件在根目录且**必须提交**；单包不要各自 `pub get`。
- **node_core 保持纯 Dart**：禁止 import Flutter/bonsoir；平台能力一律接口化注入（参考 `PlayerAdapter`、`DiscoveryChannel` 与应用侧的 `MpvPlayerAdapter`、`BonsoirDiscoveryAdapter`）。
- **协议改动**：先改 `packages/node_protocol`（Dart）并在 `docs/protocol.md` 同步，再改 web_control 的 `src/api.ts` 镜像类型（M1 接 quicktype 后消除手工镜像）。
- **注释与文档中文为主**，与仓库现有文档保持一致。
