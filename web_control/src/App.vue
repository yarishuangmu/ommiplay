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

const screen = ref<Screen>('connect')
const hostInput = ref(localStorage.getItem('omniplay_host') ?? (location.host || '127.0.0.1:47771'))
const pinInput = ref('')
const status = ref('')

const remote = ref<PlayerRemote | null>(null)
const nodeName = ref('')
const state = ref<PlayerState>()
const hasToken = ref(!!localStorage.getItem('omniplay_token'))
const playing = computed(() => state.value?.state === 'playing')

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
    // 换了地址或带了新 PIN 时重新配对。
    if (withPin || !token) {
      const result = await pairWithPin(pinInput.value.trim())
      token = result.token
      localStorage.setItem('omniplay_token', token)
      localStorage.setItem('omniplay_host', hostInput.value.trim())
      nodeName.value = result.nodeName
      hasToken.value = true
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

onBeforeUnmount(() => remote.value?.close())

const speeds = [0.5, 1.0, 1.25, 1.5, 2.0]
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
      <button v-if="hasToken" class="ghost" @click="connect(false)">
        用已有令牌直接连接
      </button>
      <p v-if="status" class="status">{{ status }}</p>
    </section>

    <!-- 控制页 -->
    <section v-else class="control">
      <header>
        <span class="dot" :class="{ live: remote }"></span>
        <strong>{{ remote?.hello?.name ?? nodeName }}</strong>
        <span class="muted">{{ remote?.hello?.nodeId }}</span>
        <button class="ghost small" @click="remote?.close()">断开</button>
      </header>

      <div v-if="state" class="pad">
        <div class="title">{{ state.title ?? '未在播放' }}</div>
        <div v-if="state.controllerName" class="muted center">受控于 {{ state.controllerName }}</div>

        <div class="row times">
          <span>{{ fmt(dragging ? dragPosition : state.positionMs) }}</span>
          <span>{{ fmt(state.durationMs) }}</span>
        </div>
        <input
          type="range"
          min="0"
          :max="Math.max(state.durationMs, 1)"
          :value="dragging ? dragPosition : state.positionMs"
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

        <div class="row">
          🔈
          <input
            type="range"
            min="0"
            max="100"
            :value="state.volume"
            @change="remote?.setVolume(Number(($event.target as HTMLInputElement).value))"
          />
        </div>

        <div class="row chips">
          <button
            v-for="rate in speeds"
            :key="rate"
            class="chip"
            :class="{ active: state.speed === rate }"
            @click="remote?.setSpeed(rate)"
          >
            {{ rate }}x
          </button>
        </div>

        <div class="row tracks">
          <select
            v-if="state.audioTracks.length"
            :value="state.currentAudio"
            @change="remote?.selectTrack('audio', Number(($event.target as HTMLSelectElement).value))"
          >
            <option v-for="t in state.audioTracks" :key="t.index" :value="t.index">
              🔊 {{ t.title ?? `音轨 ${t.index}` }}
            </option>
          </select>
          <select
            v-if="state.subtitleTracks.length"
            :value="state.currentSubtitle"
            @change="remote?.selectTrack('subtitle', Number(($event.target as HTMLSelectElement).value))"
          >
            <option v-for="t in state.subtitleTracks" :key="t.index" :value="t.index">
              💬 {{ t.title ?? `字幕 ${t.index}` }}
            </option>
          </select>
        </div>
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
            {{ s.name }}
          </button>
        </div>
        <div v-if="browseError" class="status">{{ browseError }}</div>
        <ul class="entries">
          <li v-if="dirPath" @click="browse(parentOf(dirPath))">↩︎ 上一级</li>
          <li v-for="e in entries" :key="e.path" @click="e.isDir ? browse(e.path) : playFile(e)">
            <span>{{ e.isDir ? '📂' : '🎬' }} {{ e.name }}</span>
            <span v-if="!e.isDir && e.sizeBytes" class="muted">
              {{ (e.sizeBytes / 1024 / 1024).toFixed(1) }} MB
            </span>
          </li>
        </ul>
      </div>
    </section>
  </main>
</template>
