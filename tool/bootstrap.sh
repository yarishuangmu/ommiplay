#!/usr/bin/env bash
# 首次/依赖变更后执行：Dart 依赖 + web 控制页构建
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> dart pub get（workspace 根）"
dart pub get

echo "==> web_control pnpm install + build"
cd web_control
pnpm install
pnpm build
cd ..

echo "==> 完成。运行 macOS 节点：cd apps/omniplay && flutter run -d macos"
