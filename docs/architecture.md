# 架构文档（M0-α 实施版）

> 目标设计的完整论证见《需求评估与方案选型.md》（D1–D12 决策）。本文描述**已实现**的结构。

## 分层

每个节点同构，按设备能力裁剪角色：

```
┌─────────────────────────── 节点（一台设备）───────────────────────────┐
│ 平台壳        Flutter App（macOS / Android）                          │
│              ｜ Web 控制页 Vue3 —— 任何浏览器可达，平级控制器          │
├──────────────────────────────────────────────────────────────────┤
│ 角色层   Controller(浏览/遥控) ｜ Player(会话权威) ｜ Library(内容源)  │
├──────────────────────────────────────────────────────────────────┤
│ node_core（纯 Dart，全端同一实现）                                    │
│  发现(mDNS 适配器 + UDP 信标：组播 239.255.77.88 主通道/广播尽力而为) │
│  配对(PIN+Ed25519/Web令牌)  协议(WS 封套/epoch 接管)                  │
│  播放会话(快照+续播)  流服务(HMAC+Range)                              │
│  存储(SQLite/WAL：meta、devices、progress)                           │
├──────────────────────────────────────────────────────────────────┤
│ 平台能力  media_kit(libmpv) ｜ bonsoir(mDNS, Flutter 侧) ｜ shelf     │
└──────────────────────────────────────────────────────────────────┘
```

### 关键依赖倒置

node_core 不 import 任何 Flutter/插件包。平台能力通过两个接口注入：

| 接口（node_core） | 平台实现（apps/omniplay） | 说明 |
|---|---|---|
| `PlayerAdapter` | `MpvPlayerAdapter`（media_kit） | 播放内核；测试/无头用 `FakePlayerAdapter` |
| `DiscoveryChannel` | `BonsoirDiscoveryAdapter`（bonsoir） | mDNS；node_core 内置 `UdpBeaconChannel`（UDP 信标） |

`DiscoveryMerger` 合并多通道、按 nodeId 去重、90s 超时剔除——mDNS 与信标双通道互为兜底（A1/R5）。

## 控制面 / 数据面分离

```
 [手机 C] ──WS 47771（指令/状态事件，JSON）──→ [Mac P]（会话权威）
    │                                            │
    └────────── HTTP Range /stream/<token> ──────┘
        （播放器 mpv 直接向源节点拉流，不经控制通道）
```

- 控制面：WebSocket，见 [protocol.md](./protocol.md)。
- 数据面：播放时控制器向源节点请求 `lib.stream.request`，拿到 **HMAC 签名 + 2h 过期** 的
  `/stream/<token>` URL，mpv 以 HTTP Range 直读。`NodeServer._serveFile` 实现 206/416 语义。

## 播放会话模型（A4）

- **播放器是唯一状态权威**：`PlayerSession` 持有快照，`PlayerAdapter` 每次变化推全量快照，
  广播为 `player.evt.state`；控制器连接即收 snapshot，之后增量。
- **写操作按到达序生效**（最后写入者生效）；`player.takeover` 显式接管使 `epoch+1`，
  UI 显示"受控于 X"消歧。
- **断电续播**：会话每 ≥5s 位置变化写 `progress` 表（itemKey=文件路径/URL，HLC 时间戳）；
  `load` 后若本地进度 >30s 且 <95% 自动 seek（`MpvPlayerAdapter` 用 pendingSeek 等媒体就绪）。

## 模块清单（M0-α）

| 文件 | 职责 |
|---|---|
| `packages/node_core/lib/src/hlc.dart` | HLC 混合逻辑时钟（M1 对等归集的时间基础） |
| `packages/node_core/lib/src/identity.dart` | Ed25519 设备密钥、deviceId、签名/验证 |
| `packages/node_core/lib/src/store.dart` | SQLite：meta / devices / progress |
| `packages/node_core/lib/src/pairing.dart` | PIN 生成与校验（5 分钟、一次性） |
| `packages/node_core/lib/src/discovery.dart` | 发现接口 + 多通道合并器 |
| `packages/node_core/lib/src/udp_beacon.dart` | UDP 广播信标（收包即单播回包，单向广播也能互见） |
| `packages/node_core/lib/src/node_server.dart` | shelf 单端口：/ws、/api/pair、/stream、静态页 |
| `packages/node_core/lib/src/session.dart` | 播放会话状态机 |
| `packages/node_core/lib/src/player_remote.dart` | 控制器端 WS 客户端 |
| `packages/node_core/lib/src/node.dart` | Node 组装入口 |
| `apps/omniplay/lib/services/*.dart` | 平台适配器（mpv/bonsoir/keep-awake） |
| `apps/omniplay/lib/ui/*.dart` | macOS 播放页 / Android 遥控页 / 通用遥控盘与浏览面板 |
| `web_control/src/api.ts` + `App.vue` | Web 控制器（协议类型的 TS 手工镜像） |

## M1 预留（已埋点，未实现）

- 同步：`store.progress` 已带 HLC 字段，`saveProgress` 只认更新——M1 的对等归集合并器
  直接复用该语义（进度取最远 = HLC 最大且 position 最大）。
- 协议：`sync.*` 命名空间已预留（见 protocol.md）。
- 多用户：已确认单用户，未做 profileId 字段。
