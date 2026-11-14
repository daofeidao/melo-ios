#!/usr/bin/env bash
# build_ipa.sh — Mac 本地构建 Melo IPA（免证书 + ldid 伪签，供 TrollStore 安装）
# 运行环境: macOS（建议 Monterey + Xcode 13/14），需先 brew install xcodegen ldid
# 完全离线：不访问 GitHub，从传入的本地目录直接构建
# 用法: ./build_ipa.sh [repo目录，默认 ~/melo-sync]
set -euo pipefail

REPO_DIR="${1:-$HOME/melo-sync}"
cd "$REPO_DIR"

# 若装了多份 Xcode，务必切到 13/14（2011 Sandy Bridge 无 AVX2，Xcode 15+ 会 illegal instruction 崩溃）
# sudo xcode-select -s /Applications/Xcode-14.app

BUILD_NUM="${BUILD_NUM:-$(date +%Y%m%d%H%M)}"

echo "==> 生成 Xcode 工程 (xcodegen)"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate

echo "==> 编译 (device, 不签名)"
xcodebuild \
  -project Melo.xcodeproj \
  -scheme Melo \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build-dev \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  build -quiet

APP=$(find build-dev/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)
test -n "$APP" || { echo "未找到 .app"; exit 1; }
echo "APP=$APP"

echo "==> ldid 伪签主二进制"
command -v ldid >/dev/null 2>&1 || brew install ldid
ldid -S "$APP/Melo"

echo "==> 打包 IPA"
OUT="build-dev/Melo.ipa"
rm -rf Payload "$OUT"
mkdir Payload
cp -R "$APP" Payload/
rm -rf Payload/*.app/_CodeSignature 2>/dev/null || true
zip -qr "$OUT" Payload
rm -rf Payload

echo "==> 完成 (IPA): $(pwd)/$OUT"
ls -lh "$OUT"
