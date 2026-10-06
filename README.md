# OmniPlay — 家庭多端媒体中枢

在家庭局域网内，装了应用的**任意设备都是一个节点**：既是控制器，也是播放器，还能把本机媒体分享为内容源。节点自动互相发现、一次配对全家互信；没有强制常驻的中枢——拔掉任何一台设备，剩下的照常工作。

> 需求与决策文档：[需求分析.md](./需求分析.md) ｜ [需求评估与方案选型.md](./需求评估与方案选型.md)

## 当前状态：M0-α（两端最小闭环）

| 能力 | 状态 |
|---|---|
| macOS 节点（C+P+L，libmpv + 内嵌 Web 控制页） | ✅ 已实现 |
| Android APK 节点（C+P，libmpv + 虚拟遥控器） | ✅ 已实现 |
| mDNS + UDP 信标发现 + 手动 IP 直连（三层兜底） | ✅ 已实现 |
| PIN 配对（Ed25519 设备身份 / Web 令牌） | ✅ 已实现 |
| 双向投播、遥控（进度/音量/倍速/音字幕轨）、显式接管 | ✅ 已实现 |
| 断电续播（进度本地持久化 + 自动跳转） | ✅ 已实现 |
| 签名流 URL + HTTP Range 拉流（控制面/数据面分离） | ✅ 已实现 |
| WebDAV 网络源 + 内容源远程管理（lib.source.add/remove） | ✅ 已实现 |
| 遥控器升级：方向键+OK/返回/菜单、全屏、重播、重启应用/系统、睡眠 | ✅ 已实现 |
| 仿真触控板 + 键鼠控制（TinyPlay 式电脑控制，macOS CGEvent） | ✅ 已实现（需辅助功能授权） |
| 在线影院：优酷/爱奇艺/腾讯视频/B站（桌面 WebView 承载） | ✅ 已实现（R2 尽力而为） |
上面已实现（含手柄仿真（M0-γ）） + M1-α 插件化骨架（PluginManager + CapabilityRegistry 卸载路径 + UserScriptHook）
| 插件 | ✅ 骨架完成（M1-α：PluginManager + 用户脚本引擎 + iQiyi 示例）；Mac WebView 注入通道/Web 商店 UI 待下轮 |
| 对等归集同步（A7）、转码、Emby/IPTV、刮削 | ⏳ M1+ |

## 仓库结构

```
media-hub/
├─ apps/omniplay/        # Flutter 双端节点应用（macOS + Android）
├─ packages/node_core/   # 纯 Dart 节点核心（发现/配对/协议/会话/流服务）
├─ packages/node_protocol/ # WS 消息协议（封套 + 载荷模型）
├─ web_control/          # Vue3 Web 控制页（构建产物由节点托管）
├─ docs/                 # 开发文档（架构 / 协议规范 / 开发指南）
└─ tool/                 # 常用脚本
```

## 快速开始

环境要求：Flutter ≥3.47（含 macOS desktop 与 Android 工具链）、Node ≥20 + pnpm、CocoaPods。详见 [docs/development.md](./docs/development.md)。

```bash
./tool/bootstrap.sh        # 首次：依赖安装 + web 控制页构建
./tool/test.sh             # Dart 单测 + 集成测试（22 个）
cd apps/omniplay && flutter run -d macos      # 运行 macOS 节点
cd apps/omniplay && flutter run -d <安卓设备>  # 运行 Android 节点
```

体验闭环（M0 验收路径）：

1. Mac 上运行 app → 侧栏点 **+** 选择媒体目录（NAS SMB 挂载点或本地文件夹）；
2. 手机安装 APK，打开「遥控」页 → 出现 Mac 节点 → 点开输入 Mac 屏幕上的 **PIN**；
3. 手机上「浏览并投片」选一部片子 → Mac 开始播放，遥控盘可拖进度/调音量/切音轨字幕；
4. 反向也成立：手机「本机播放」页可被投片；浏览器打开 `http://<Mac IP>:47771` 同样是控制器。

## 文档索引

- [docs/architecture.md](./docs/architecture.md) — 分层架构、控制面/数据面分离、会话模型
- [docs/protocol.md](./docs/protocol.md) — WS 消息协议 v1 规范（封套/命名空间/配对握手/流 URL）
- [docs/development.md](./docs/development.md) — 环境、命令、双端联调、打包、故障排查
