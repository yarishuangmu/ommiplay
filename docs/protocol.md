# WS 消息协议 v1

> 实现：Dart 侧 `packages/node_protocol`（权威），TS 侧 `web_control/src/api.ts`（手工镜像，M1 接 quicktype）。

## 封套

所有消息为一条 JSON 文本帧：

```json
{
  "v": 1,
  "type": "player.cmd.seek",
  "id": "3f8a…",
  "ts": "0001791221864123.000004.<nodeId>",
  "from": "<nodeId>",
  "payload": { "positionMs": 42000 }
}
```

- `v`：协议版本。接收方拒绝 `v > 本端` 的大版本（semver：大版本不兼容、小版本向后兼容）。
- `ts`：**HLC**（混合逻辑时钟）字符串，编码保证字典序 == 时间序，抗设备时钟偏移。
- `id`：16 字节随机 hex；`from`：发送方 nodeId。

## 命名空间

| 前缀 | 方向 | 说明 |
|---|---|---|
| `node.*` | 双向 | 自我宣告、错误 |
| `pair.*` | 握手 | 配对与认证（连接建立后第一批消息） |
| `lib.*` | C→P 请求 | 内容源枚举/浏览/流地址 |
| `player.cmd.*` | C→P | 播放指令 |
| `player.evt.*` | P→C | 播放状态事件（全量快照） |
| `player.takeover` | C→P | 显式接管 |
| `sync.*` | 预留 | M1 对等归集（offer/pull/batch/ack） |

## 连接与认证

1. 客户端连 `ws://<host>:47771/ws`。
2. 服务端立即发 `pair.challenge {nonce}`。
3. 客户端三选一：
   - **已配对的原生设备**：`pair.auth.request {deviceId, sig}`，sig = Ed25519 签名(nonce)；
   - **首次配对**：`pair.pin.request {pin, deviceId, name, pubKey}`（PIN 5 分钟有效、一次性）；
   - **浏览器**：先 `POST /api/pair {pin, name}` 换一次性随机令牌（服务端只存 sha256），
     再 `pair.auth.request {token}`。
4. 服务端回 `pair.pin.response` / `pair.auth.result {ok, error?}`；成功后推送**欢迎包**：
   `node.hello`（NodeInfo）→ `lib.sources` → `player.evt.state`（当前快照）。

未认证连接仅允许 `pair.*` 与 `node.hello`，其余一律 `node.error {code:"unauthorized"}`。
吊销：devices 表 `revoked` 标记，被吊销设备认证失败（M1 起随同步全网扩散）。

## 消息清单（v1 实现）

| type | payload | 说明 |
|---|---|---|
| `node.hello` | `{nodeId,name,roles,protoVer,httpPort}` | 节点自我宣告 |
| `node.error` | `{code,message}` | 错误（bad-message/unauthorized/unknown-command/…） |
| `pair.challenge` | `{nonce}` | 服务端→客户端 |
| `pair.pin.request` | `{pin,deviceId,name,pubKey}` | 首次配对 |
| `pair.pin.response` | `{ok,error?,nodeId?,nodeName?,familyId?,hostDevice?}` | `hostDevice` 为主机端设备记录 `{deviceId,name,pubKey}`，加入方必须落库（A2 互换语义） |
| `pair.auth.request` | `{deviceId,sig}` 或 `{token}` | 挑战应答 / Web 令牌 |
| `pair.auth.result` | `{ok,error?,nodeName?}` | |
| `lib.sources` | `{sources:[{sourceId,name,root,kind}], reqId?}` | 带 reqId 视为请求-响应；kind: folder\|webdav |
| `lib.browse.request` | `{reqId,sourceId,dirPath}` | dirPath 为源内相对路径 |
| `lib.browse.response` | `{reqId,ok,entries:[{name,path,isDir,sizeBytes?}]}` | 目录优先排序 |
| `lib.source.add` | `{reqId,kind,name?,url?,username?,password?,path?}` | 远端添加内容源（kind: folder\|webdav）；webdav 添加时主机侧先 PROPFIND 校验 |
| `lib.source.remove` | `{reqId,sourceId}` | 远端移除内容源 |
| `lib.stream.request` | `{reqId,sourceId,path}` | |
| `lib.stream.response` | `{reqId,ok,url?,localPath?,expiresAt?}` | url=`http://<lan>:47771/stream/<token>` |
| `player.cmd.load` | `{kind:'file'\|'url', value, title?}` | kind=url 时 value 为签名流地址 |
| `player.cmd.play/pause/stop` | `{}` | |
| `player.cmd.seek` | `{positionMs}` | |
| `player.cmd.setVolume` | `{volume:0-100}` | |
| `player.cmd.setSpeed` | `{rate}` | |
| `player.cmd.selectTrack` | `{kind:'audio'\|'subtitle', index}` | |
| `player.evt.state` | PlayerState（见下） | 每次变化广播全量快照 |
| `player.takeover` | `{}` | epoch+1，广播状态携带新 controllerName |
| `player.cmd.key` | `{key}` | 语义按键：up/down/left/right/ok/playPause/back/restart/fullscreen，会话映射为音量/快进退/暂停/重播/全屏 |
| `node.cmd.restartApp` | `{}` | 重启节点应用（macOS 重新拉起 bundle；移动端退出进程） |
| `node.cmd.rebootSystem` | `{}` | 重启节点系统（仅桌面，AppleScript，需授权） |
| `node.cmd.sleepSystem` | `{}` | 节点系统睡眠（macOS `pmset sleepnow`） |
| `input.mouseMove` | `{dx,dy}` | 仿真触控板：移动鼠标（CGEvent，需辅助功能授权） |
| `input.mouseClick` | `{button:'left'\|'right', doubleClick}` | 鼠标点击 |
| `input.mouseScroll` | `{dx,dy}` | 滚轮 |
| `input.keyPress` | `{key}` | 命名按键直通（up/enter/esc/space/f/p/m/volumeUp…），网页里 F=全屏、空格=播放 |
| `input.text` | `{text}` | 直接键入文本（CGEvent Unicode，中文尽力而为） |
| `web.open` | `{url,title?}` | 桌面节点内置 WebView 打开在线站点（优酷/爱奇艺/腾讯视频/B站），仅桌面支持 |
| `web.close` | `{}` | 关闭网页窗口 |

### PlayerState（player.evt.state 载荷）

```json
{
  "epoch": 0,
  "controllerId": "…", "controllerName": "手机",
  "state": "idle|buffering|playing|paused|ended",
  "positionMs": 0, "durationMs": 0,
  "speed": 1.0, "volume": 100,
  "title": "…", "source": "/path/or/url",
  "audioTracks": [{"index":0,"title":"…"}],
  "subtitleTracks": [{"index":0,"title":"…"}],
  "currentAudio": 0, "currentSubtitle": null
}
```

## 安全模型（v1，与选型 D8 一致）

- **防误入/扫描**：全部 API/WS 需配对或认证；发现 TXT 仅含 `{id,ver,name}`，能力配对后获取。
- **不防主动中间人**：局域网明文传输 + 逐连接签名认证是 v1 的明确取舍（家庭网络威胁模型）。
- 演进：v1.1 起节点自签证书 TLS + 配对时交换家庭 CA pinning，不动协议层。
- 流 URL：HMAC-SHA256 签名（节点启动生成的随机密钥，持久化于 meta）+ 2 小时过期 + 路径绑定。

## 兼容性规则

新增消息类型 / payload 可选字段 = 小版本升级（双方共存）；
改动既有字段语义或删除字段 = 大版本升级（hello 握手拒绝并提示升级）。
