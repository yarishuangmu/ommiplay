#!/usr/bin/env bash
# 测试门禁：核心包测试 + 应用静态检查
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> dart analyze packages"
dart analyze packages

echo "==> dart test packages"
dart test packages

echo "==> flutter analyze（apps/omniplay）"
cd apps/omniplay
flutter analyze
