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
- **Windows 防火墙**（未来平台）：首启需放行 47771 入站。
- **端口被占**：日志会抛 SocketException；改 NodeConfig 端口或释放占用。
- **PIN 一直无效**：PIN 5 分钟过期且一次性，用播放器页"刷新"重新生成。
- **Android 上收不到信标**：已实现 MulticastLock（MainActivity），若仍失败属机型限制，走手动直连。

## 打包发布（M0）

- **macOS**：`flutter build macos --release` → `apps/omniplay/build/macos/Build/Products/Release/omniplay.app`（当前 entitlements 已关闭 App Sandbox，仅限家庭自用，勿上架）。
- **Android**：`flutter build apk --split-per-abi --release` → `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（split-per-abi 显著减小体积，media_kit 官方建议）。
- Web 控制页：`cd web_control && pnpm build` → `dist/`；macOS 运行时若在仓库内会自动托管该目录（apps/omniplay/lib/main.dart 的 `_webRoot()`），APK 不托管 Web 页（手机节点用原生 UI）。

## 工程约定

- **pub workspace**：根 `pubspec.yaml` 列出全部 Dart 包，锁文件在根目录且**必须提交**；单包不要各自 `pub get`。
- **node_core 保持纯 Dart**：禁止 import Flutter/bonsoir；平台能力一律接口化注入（参考 `PlayerAdapter`、`DiscoveryChannel` 与应用侧的 `MpvPlayerAdapter`、`BonsoirDiscoveryAdapter`）。
- **协议改动**：先改 `packages/node_protocol`（Dart）并在 `docs/protocol.md` 同步，再改 web_control 的 `src/api.ts` 镜像类型（M1 接 quicktype 后消除手工镜像）。
- **注释与文档中文为主**，与仓库现有文档保持一致。
