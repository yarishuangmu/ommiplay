<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from 'vue'
import {
  PlayerRemote,
  pairWithPin,
  type LibEntry,
  type PlayerState,
  type SourceInfo,
} from './api'

type Screen = 'connect' | 'control'
type Tab = 'pad' | 'touch' | 'keys'

const screen = ref<Screen>('connect')
const hostInput = ref(localStorage.getItem('omniplay_host') ?? (location.host || '127.0.0.1:47771'))
const pinInput = ref('')
const status = ref('')

const remote = ref<PlayerRemote | null>(null)
const nodeName = ref('')
const state = ref<PlayerState>()
const hasToken = ref(!!localStorage.getItem('omniplay_token'))
const playing = computed(() => state.value?.state === 'playing')
const tab = ref<Tab>('pad')

// 进度条拖拽
const dragging = ref(false)
const dragPosition = ref(0)

// 浏览
const showBrowse = ref(false)
const sources = ref<SourceInfo[]>([])
const currentSource = ref<SourceInfo | null>(null)
const dirPath = ref('')
const entries = ref<LibEntry[]>([])
const browseError = ref('')

// 在线影院 / 电源
const showSites = ref(false)
const showPower = ref(false)
const customUrl = ref('')

const sites: Array<[string, string]> = [
  ['优酷', 'https://www.youku.com/'],
  ['爱奇艺', 'https://www.iqiyi.com/'],
  ['腾讯视频', 'https://v.qq.com/'],
  ['哔哩哔哩', 'https://www.bilibili.com/'],
]

const keyButtons = [
  'space', 'enter', 'esc', 'up', 'down', 'left', 'right',
  'f', 'p', 'm', 'volumeUp', 'volumeDown', 'mute',
]

// 触控板状态
let lastPointer: { x: number; y: number } | null = null

function fmt(ms: number): string {
  const total = Math.floor(ms / 1000)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const two = (v: number) => v.toString().padStart(2, '0')
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${two(m)}:${two(s)}`
}

async function connect(withPin: boolean) {
  status.value = '连接中……'
  try {
    let token = localStorage.getItem('omniplay_token') ?? ''
    if (withPin || !token) {
      const result = await pairWithPin(pinInput.value.trim())
      token = result.token
      localStorage.setItem('omniplay_token', token)
      localStorage.setItem('omniplay_host', hostInput.value.trim())
      nodeName.value = result.nodeName
    }
    const r = await PlayerRemote.connect(hostInput.value.trim(), token)
    remote.value = r
    r.onState = (s) => (state.value = s)
    r.onClose = () => {
      status.value = '连接已断开'
      remote.value = null
      screen.value = 'connect'
    }
    screen.value = 'control'
    status.value = ''
  } catch (error) {
    status.value = `失败：${error instanceof Error ? error.message : error}`
  }
}

async function openBrowse() {
  if (!remote.value) return
  showBrowse.value = true
  browseError.value = ''
  try {
    sources.value = await remote.value.refreshSources()
    if (sources.value.length > 0) await pickSource(sources.value[0])
  } catch (error) {
    browseError.value = String(error)
  }
}

async function pickSource(source: SourceInfo) {
  if (!remote.value) return
  currentSource.value = source
  dirPath.value = ''
  try {
    entries.value = await remote.value.browse(source.sourceId, '')
  } catch (error) {
    browseError.value = String(error)
  }
}

async function browse(dir: string) {
  if (!remote.value || !currentSource.value) return
  dirPath.value = dir
  try {
    entries.value = await remote.value.browse(currentSource.value.sourceId, dir)
  } catch (error) {
    browseError.value = String(error)
  }
}

async function playFile(entry: LibEntry) {
  if (!remote.value || !currentSource.value) return
  const stream = await remote.value.requestStream(currentSource.value.sourceId, entry.path)
  remote.value.loadMedia(stream.url ? 'url' : 'file', stream.url ?? stream.localPath ?? entry.path, entry.name)
  showBrowse.value = false
}

function onSeekEnd() {
  if (!remote.value || !state.value) return
  remote.value.seekMs(Math.round(dragPosition.value))
  dragging.value = false
}

function parentOf(path: string): string {
  const index = path.lastIndexOf('/')
  return index <= 0 ? '' : path.substring(0, index)
}

async function openSite(url: string) {
  if (!remote.value) return
  try {
    await remote.value.webOpen(url)
    showSites.value = false
  } catch (error) {
    status.value = `打开失败：${error instanceof Error ? error.message : error}`
  }
}

function openCustom() {
  const url = customUrl.value.trim()
  if (url) openSite(url.startsWith('http') ? url : `https://${url}`)
}

// 触控板：滑动=移动，轻点=左键，双击=双击
function onTouchDown(e: PointerEvent) {
  lastPointer = { x: e.clientX, y: e.clientY }
}
function onTouchMove(e: PointerEvent) {
  if (!lastPointer || !remote.value) return
  remote.value.mouseMove(e.clientX - lastPointer.x, e.clientY - lastPointer.y)
  lastPointer = { x: e.clientX, y: e.clientY }
}
function onTouchUp() {
  lastPointer = null
}
function onTouchScroll(e: WheelEvent) {
  remote.value?.mouseScroll(0, e.deltaY > 0 ? 3 : -3)
}

const textInput = ref('')
function sendText() {
  const text = textInput.value
  if (text && remote.value) {
    remote.value.inputText(text)
    textInput.value = ''
  }
}

onBeforeUnmount(() => remote.value?.close())
</script>

<template>
  <main class="app">
    <!-- 连接页 -->
    <section v-if="screen === 'connect'" class="connect">
      <h1>OmniPlay 控制页</h1>
      <p class="hint">打开任意节点的地址即为控制器 —— 输入节点屏幕上的 6 位 PIN 完成配对。</p>
      <label>
        节点地址
        <input v-model="hostInput" placeholder="192.168.1.100:47771" />
      </label>
      <label>
        配对 PIN
        <input v-model="pinInput" inputmode="numeric" maxlength="6" placeholder="6 位数字" />
      </label>
      <button class="primary" @click="connect(true)">配对并控制</button>
      <button v-if="hasToken" class="ghost" @click="connect(false)">用已有令牌直接连接</button>
      <p v-if="status" class="status">{{ status }}</p>
    </section>

    <!-- 控制页 -->
    <section v-else class="control">
      <header>
        <span class="dot" :class="{ live: remote }"></span>
        <strong>{{ remote?.hello?.name ?? nodeName }}</strong>
        <button class="ghost small" title="在线影院（优酷/爱奇艺/腾讯…）" @click="showSites = true">在线影院</button>
        <button class="ghost small" title="电源/系统" @click="showPower = true">电源</button>
        <button class="ghost small" @click="remote?.close()">断开</button>
      </header>

      <nav class="tabs">
        <button :class="{ active: tab === 'pad' }" @click="tab = 'pad'">遥控盘</button>
        <button :class="{ active: tab === 'touch' }" @click="tab = 'touch'">触控板</button>
        <button :class="{ active: tab === 'keys' }" @click="tab = 'keys'">键盘</button>
      </nav>

      <!-- 遥控盘 -->
      <div v-if="tab === 'pad'" class="pad">
        <div class="title">{{ state?.title ?? '未在播放' }}</div>
        <div v-if="state?.controllerName" class="muted center">受控于 {{ state.controllerName }}</div>

        <div class="row times">
          <span>{{ fmt(dragging ? dragPosition : state?.positionMs ?? 0) }}</span>
          <span>{{ fmt(state?.durationMs ?? 0) }}</span>
        </div>
        <input
          type="range"
          min="0"
          :max="Math.max(state?.durationMs ?? 0, 1)"
          :value="dragging ? dragPosition : state?.positionMs ?? 0"
          @input="dragging = true; dragPosition = Number(($event.target as HTMLInputElement).value)"
          @change="onSeekEnd"
        />

        <div class="row buttons">
          <button class="icon" title="停止" @click="remote?.stop()">■</button>
          <button class="primary big" @click="playing ? remote?.pause() : remote?.play()">
            {{ playing ? '暂停' : '播放' }}
          </button>
          <button class="icon" title="浏览内容源并投片" @click="openBrowse">📁</button>
        </div>

        <div class="dpad">
          <div class="dpad-grid">
            <button class="dpad-key" @click="remote?.sendKey('up')">↑</button>
            <button class="dpad-key" @click="remote?.sendKey('left')">←</button>
            <button class="dpad-key ok" @click="remote?.sendKey('ok')">OK</button>
            <button class="dpad-key" @click="remote?.sendKey('right')">→</button>
            <button class="dpad-key" @click="remote?.sendKey('down')">↓</button>
          </div>
          <div class="dpad-side">
            <button class="dpad-key wide" @click="remote?.sendKey('back')">返回</button>
            <button class="dpad-key wide" @click="remote?.sendKey('menu')">菜单</button>
          </div>
        </div>

        <div class="row center">
          <button class="ghost" @click="remote?.sendKey('fullscreen')">⛶ 全屏</button>
          <button class="ghost" @click="remote?.sendKey('restart')">↺ 重播</button>
        </div>

        <div class="row">
          🔈
          <input
            type="range"
            min="0"
            max="100"
            :value="state?.volume ?? 100"
            @change="remote?.setVolume(Number(($event.target as HTMLInputElement).value))"
          />
        </div>

        <div class="row chips">
          <button
            v-for="rate in [0.5, 1.0, 1.25, 1.5, 2.0]"
            :key="rate"
            class="chip"
            :class="{ active: state?.speed === rate }"
            @click="remote?.setSpeed(rate)"
          >
            {{ rate }}x
          </button>
        </div>

        <div class="row tracks">
          <select
            v-if="state?.audioTracks.length"
            :value="state.currentAudio"
            @change="remote?.selectTrack('audio', Number(($event.target as HTMLSelectElement).value))"
          >
            <option v-for="t in state.audioTracks" :key="t.index" :value="t.index">
              🔊 {{ t.title ?? `音轨 ${t.index}` }}
            </option>
          </select>
          <select
            v-if="state?.subtitleTracks.length"
            :value="state.currentSubtitle"
            @change="remote?.selectTrack('subtitle', Number(($event.target as HTMLSelectElement).value))"
          >
            <option v-for="t in state.subtitleTracks" :key="t.index" :value="t.index">
              💬 {{ t.title ?? `字幕 ${t.index}` }}
            </option>
          </select>
        </div>
      </div>

      <!-- 触控板（TinyPlay 式电脑控制，仅桌面节点支持） -->
      <div v-else-if="tab === 'touch'" class="touch">
        <div
          class="touchpad"
          @pointerdown="onTouchDown"
          @pointermove="onTouchMove"
          @pointerup="onTouchUp"
          @pointerleave="onTouchUp"
          @dblclick="remote?.mouseClick('left', true)"
          @contextmenu.prevent="remote?.mouseClick('right')"
        >
          触控板 · 滑动=移动 · 轻点=左键 · 双击=双击 · 右键=右键
        </div>
        <div class="scrollpad" @wheel.prevent="onTouchScroll">滚动区（滚轮/拖动）</div>
        <div class="row center">
          <button class="primary" @click="remote?.mouseClick()">左键</button>
          <button class="primary" @click="remote?.mouseClick('right')">右键</button>
        </div>
        <p class="muted center">适用于桌面节点（Mac/PC）：可直接操作在线影院网页与系统。</p>
      </div>

      <!-- 键盘 -->
      <div v-else class="keys">
        <div class="row">
          <input v-model="textInput" placeholder="输入文字，直接键入到节点" @keyup.enter="sendText" />
          <button class="primary" @click="sendText">键入</button>
        </div>
        <div class="row chips">
          <button v-for="k in keyButtons" :key="k" class="chip" @click="remote?.keyPress(k)">{{ k }}</button>
        </div>
        <p class="muted center">网页里 F=全屏、空格=播放/暂停、←→=快进退</p>
      </div>

      <!-- 浏览投片 -->
      <div v-if="showBrowse" class="browse">
        <div class="browse-head">
          <strong>浏览并投片</strong>
          <button class="ghost small" @click="showBrowse = false">关闭</button>
        </div>
        <div v-if="sources.length > 1" class="row chips">
          <button
            v-for="s in sources"
            :key="s.sourceId"
            class="chip"
            :class="{ active: s === currentSource }"
            @click="pickSource(s)"
          >
            {{ s.name }} [{{ s.kind }}]
          </button>
        </div>
        <div v-if="browseError" class="status">{{ browseError }}</div>
        <ul class="entries">
          <li v-if="dirPath" @click="browse(parentOf(dirPath))">↩︎ 上一级</li>
          <li v-for="e in entries" :key="e.path" @click="e.isDir ? browse(e.path) : playFile(e)">
            <span>{{ e.isDir ? '📂' : '🎬' }} {{ e.name }}</span>
            <span v-if="!e.isDir && e.sizeBytes" class="muted">{{ (e.sizeBytes / 1024 / 1024).toFixed(1) }} MB</span>
          </li>
        </ul>
      </div>

      <!-- 在线影院 -->
      <div v-if="showSites" class="modal" @click.self="showSites = false">
        <div class="modal-body">
          <div class="browse-head">
            <strong>在节点上打开网页播放</strong>
            <button class="ghost small" @click="showSites = false">关闭</button>
          </div>
          <button v-for="[name, url] in sites" :key="url" class="site" @click="openSite(url)">
            <span>▶</span> {{ name }} <span class="muted">{{ url }}</span>
          </button>
          <div class="row">
            <input v-model="customUrl" placeholder="自定义网址 https://…" />
            <button class="primary" @click="openCustom">打开</button>
          </div>
          <p class="muted">仅桌面节点支持；打开后用「触控板/键盘」操作网页。</p>
        </div>
      </div>

      <!-- 电源菜单 -->
      <div v-if="showPower" class="modal" @click.self="showPower = false">
        <div class="modal-body">
          <div class="browse-head">
            <strong>电源 / 系统</strong>
            <button class="ghost small" @click="showPower = false">关闭</button>
          </div>
          <button class="site" @click="remote?.sendKey('restart'); showPower = false">↺ 重播当前媒体</button>
          <button class="site" @click="remote?.sendKey('fullscreen'); showPower = false">⛶ 全屏切换</button>
          <button class="site" @click="remote?.restartApp(); showPower = false">⟳ 重启节点应用</button>
          <button class="site" @click="remote?.rebootSystem(); showPower = false">⟳ 重启节点系统（需授权）</button>
          <button class="site" @click="remote?.sleepSystem(); showPower = false">🌙 让节点系统睡眠</button>
        </div>
      </div>
    </section>
  </main>
</template>
