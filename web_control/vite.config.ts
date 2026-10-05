import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vite'

// 开发期代理：页面直连本机节点（生产由节点托管 dist，无需代理）。
export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:47771',
      '/ws': { target: 'ws://127.0.0.1:47771', ws: true },
      '/stream': 'http://127.0.0.1:47771',
    },
  },
})
