/**
 * OmniPlay Web 控制页 —— 协议客户端。
 *
 * 与 node_protocol（Dart）保持一致的消息封套与类型（schema 稳定后 M1 接 quicktype 生成）。
 * 认证：浏览器无密钥对，走 PIN → 随机令牌（POST /api/pair，localStorage 保存）→ WS pair.auth.request。
 */

export const PROTOCOL_VERSION = 1

export interface Msg {
  v: number
  type: string
  id: string
  ts: string
  from: string
  payload: Record<string, unknown>
}

export interface NodeInfo {
  nodeId: string
  name: string
  roles: string[]
  protoVer: number
  httpPort: number
}

export interface SourceInfo {
  sourceId: string
  name: string
  root: string
  kind?: string
}

export interface LibEntry {
  name: string
  path: string
  isDir: boolean
  sizeBytes?: number
}

export interface TrackRef {
  index: number
  title?: string
}

export type PlaybackStateName = 'idle' | 'buffering' | 'playing' | 'paused' | 'ended'

export interface PlayerState {
  epoch: number
  controllerId?: string
  controllerName?: string
  state: PlaybackStateName
  positionMs: number
  durationMs: number
  speed: number
  volume: number
  title?: string
  source?: string
  audioTracks: TrackRef[]
  subtitleTracks: TrackRef[]
  currentAudio?: number
  currentSubtitle?: number
}

function newId(): string {
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
}

export class PlayerRemoteError extends Error {}

export class PlayerRemote {
  private ws?: WebSocket
  private token?: string
  private authWaiter?: {
    resolve: (payload: Record<string, unknown>) => void
    reject: (error: Error) => void
  }
  private pending = new Map<string, (payload: Record<string, unknown>) => void>()

  hello?: NodeInfo
  state?: PlayerState
  onState?: (state: PlayerState) => void
  onClose?: () => void

  /** 连接并认证：收到 pair.challenge 即用令牌应答，auth.result 完成握手。 */
  static async connect(host: string, token: string): Promise<PlayerRemote> {
    const remote = new PlayerRemote()
    remote.token = token

    const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${host}/ws`
    const ws = new WebSocket(url)
    remote.ws = ws
    ws.onmessage = (event) => remote.onMessage(JSON.parse(event.data as string) as Msg)
    ws.onclose = () => remote.onClose?.()

    const auth = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => reject(new PlayerRemoteError('认证超时')), 8000)
      remote.authWaiter = {
        resolve: (payload) => {
          clearTimeout(timer)
          resolve(payload)
        },
        reject: (error) => {
          clearTimeout(timer)
          reject(error)
        },
      }
    })

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new PlayerRemoteError('连接超时')), 8000)
      ws.onopen = () => {
        clearTimeout(timer)
        resolve()
      }
      ws.onerror = () => {
        clearTimeout(timer)
        reject(new PlayerRemoteError('无法连接节点'))
      }
    })

    const result = await auth
    if (!result['ok']) {
      throw new PlayerRemoteError(String(result['error'] ?? '认证失败'))
    }
    return remote
  }

  private onMessage(msg: Msg) {
    switch (msg.type) {
      case 'pair.challenge':
        this.send('pair.auth.request', { token: this.token })
        return
      case 'pair.auth.result': {
        const waiter = this.authWaiter
        this.authWaiter = undefined
        waiter?.resolve(msg.payload)
        return
      }
      case 'node.hello':
        this.hello = msg.payload as unknown as NodeInfo
        return
      case 'player.evt.state':
        this.state = msg.payload as unknown as PlayerState
        this.onState?.(this.state)
        return
      default: {
        const reqId = msg.payload['reqId'] as string | undefined
        if (reqId) {
          const resolver = this.pending.get(reqId)
          if (resolver) {
            this.pending.delete(reqId)
            resolver(msg.payload)
          }
        }
      }
    }
  }

  private send(type: string, payload: Record<string, unknown>) {
    this.ws?.send(
      JSON.stringify({
        v: PROTOCOL_VERSION,
        type,
        id: newId(),
        ts: `${Date.now().toString().padStart(15, '0')}.000000.web`,
        from: 'web-controller',
        payload,
      } satisfies Msg),
    )
  }

  private async request(type: string, payload: Record<string, unknown>): Promise<Record<string, unknown>> {
    const reqId = newId()
    const promise = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(reqId)
        reject(new PlayerRemoteError('请求超时'))
      }, 8000)
      this.pending.set(reqId, (response) => {
        clearTimeout(timer)
        resolve(response)
      })
    })
    this.send(type, { reqId, ...payload })
    return promise
  }

  // ------------------------------------------------------------- 业务 ----

  async refreshSources(): Promise<SourceInfo[]> {
    const payload = await this.request('lib.sources', {})
    return (payload['sources'] as SourceInfo[]) ?? []
  }

  async browse(sourceId: string, dirPath: string): Promise<LibEntry[]> {
    const payload = await this.request('lib.browse.request', { sourceId, dirPath })
    if (!payload['ok']) throw new PlayerRemoteError(String(payload['error'] ?? '浏览失败'))
    return (payload['entries'] as LibEntry[]) ?? []
  }

  async requestStream(sourceId: string, path: string): Promise<{ url?: string; localPath?: string }> {
    const payload = await this.request('lib.stream.request', { sourceId, path })
    if (!payload['ok']) throw new PlayerRemoteError(String(payload['error'] ?? '获取流地址失败'))
    return {
      url: payload['url'] as string | undefined,
      localPath: payload['localPath'] as string | undefined,
    }
  }

  loadMedia(kind: string, value: string, title?: string) {
    this.send('player.cmd.load', { kind, value, ...(title ? { title } : {}) })
  }
  play() {
    this.send('player.cmd.play', {})
  }
  pause() {
    this.send('player.cmd.pause', {})
  }
  stop() {
    this.send('player.cmd.stop', {})
  }
  seekMs(positionMs: number) {
    this.send('player.cmd.seek', { positionMs })
  }
  setVolume(volume: number) {
    this.send('player.cmd.setVolume', { volume })
  }
  setSpeed(rate: number) {
    this.send('player.cmd.setSpeed', { rate })
  }
  selectTrack(kind: string, index: number) {
    this.send('player.cmd.selectTrack', { kind, index })
  }
  takeover() {
    this.send('player.takeover', {})
  }

  // —— 语义按键（遥控器方向键/OK/返回…，播放器会话自行映射）——
  sendKey(key: string) {
    this.send('player.cmd.key', { key })
  }

  // —— PC 控制（仿真触控板/键鼠，仅桌面节点）——
  mouseMove(dx: number, dy: number) {
    this.send('input.mouseMove', { dx, dy })
  }
  mouseClick(button = 'left', doubleClick = false) {
    this.send('input.mouseClick', { button, doubleClick })
  }
  mouseScroll(dx: number, dy: number) {
    this.send('input.mouseScroll', { dx, dy })
  }
  keyPress(key: string) {
    this.send('input.keyPress', { key })
  }
  inputText(text: string) {
    this.send('input.text', { text })
  }

  // —— 在线影院（桌面节点内置 WebView 承载）——
  webOpen(url: string, title?: string) {
    return this.request('web.open', { url, ...(title ? { title } : {}) })
  }
  webClose() {
    this.send('web.close', {})
  }

  // —— 系统（重启/睡眠）——
  restartApp() {
    this.send('node.cmd.restartApp', {})
  }
  rebootSystem() {
    this.send('node.cmd.rebootSystem', {})
  }
  sleepSystem() {
    this.send('node.cmd.sleepSystem', {})
  }
  close() {
    this.ws?.close()
  }
}

/** PIN 配对：POST /api/pair 换取浏览器令牌。 */
export async function pairWithPin(pin: string): Promise<{ token: string; nodeName: string }> {
  const response = await fetch('/api/pair', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pin, name: 'Web 控制页' }),
  })
  const body = (await response.json()) as {
    ok: boolean
    token?: string
    nodeName?: string
    error?: string
  }
  if (!body.ok || !body.token) throw new PlayerRemoteError(body.error ?? '配对失败')
  return { token: body.token, nodeName: body.nodeName ?? 'OmniPlay 节点' }
}
