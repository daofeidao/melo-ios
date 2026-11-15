#!/usr/bin/env bash
# build_ipa.sh — 在 Mac 上本地构建 Melo IPA（免证书 + ldid 伪签，供 TrollStore / 自签工具安装）
#
# 面向 2011 MacBook Pro（A1278 / Sandy Bridge）+ OCLP macOS 13 Ventura：
#   该机型没有 AVX2，Xcode 15 及以上的 Swift 前端会 illegal instruction 直接崩，
#   所以必须用 Xcode 14.x（14.3 是 Ventura 上的稳定选择）。脚本会检查并告警。
#
# 用法：
#   ./build_ipa.sh                          # 构建 ~/melo-sync
#   ./build_ipa.sh /path/to/repo            # 构建指定目录
#   ./build_ipa.sh --keep-build             # 复用上次的 build-dev，快一点（有陈旧产物风险）
#   MARKETING_VERSION=2.0.1 ./build_ipa.sh  # 覆盖版本号（默认读 project.yml）
#   BUILD_NUM=118 ./build_ipa.sh            # 覆盖构建号（默认时间戳）
#
# 产物：<repo>/dist/Melo-v<版本>.B<构建号>.ipa
# 末行固定输出三行机器可读信息，供 Windows 端 mac_build.py 解析：
#   IPA_PATH=...
#   IPA_SIZE=...
#   IPA_MD5=...
set -euo pipefail

# ---------- 参数 ----------
REPO_DIR=""
KEEP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --keep-build) KEEP_BUILD=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "未知参数: $arg" >&2; exit 2 ;;
    *) REPO_DIR="$arg" ;;
  esac
done
REPO_DIR="${REPO_DIR:-$HOME/melo-sync}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$REPO_DIR" ] || die "目录不存在: $REPO_DIR"
cd "$REPO_DIR"
[ -f project.yml ] || die "$REPO_DIR 里没有 project.yml，不像 Melo 仓库"

# ---------- 环境检查 ----------
[ "$(uname -s)" = "Darwin" ] || die "这个脚本只能在 macOS 上跑"

XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
[ -n "${XCODE_VER:-}" ] || die "找不到 xcodebuild，请先安装 Xcode 并 sudo xcode-select -s /Applications/Xcode.app"
XCODE_MAJOR=${XCODE_VER%%.*}
say "Xcode 版本: $XCODE_VER"

CPU_FEAT=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null || true)
if [ "$XCODE_MAJOR" -ge 15 ] && ! echo "$CPU_FEAT" | grep -qi AVX2; then
  cat >&2 <<'WARN'
------------------------------------------------------------
警告：这台机器的 CPU 没有 AVX2，但当前 Xcode 是 15 及以上。
      Swift 编译器会以 illegal instruction 崩溃（SIGILL）。
      请安装 Xcode 14.3 并切过去：
        sudo xcode-select -s /Applications/Xcode-14.3.app
------------------------------------------------------------
WARN
  exit 3
fi

command -v xcodegen >/dev/null 2>&1 || die "缺 xcodegen：brew install xcodegen"
HAVE_LDID=1
command -v ldid >/dev/null 2>&1 || HAVE_LDID=0

# ---------- 版本号 ----------
if [ -z "${MARKETING_VERSION:-}" ]; then
  MARKETING_VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([0-9]+(\.[0-9]+)*)".*/\1/')
fi
[ -n "${MARKETING_VERSION:-}" ] || die "读不到版本号，请用 MARKETING_VERSION=2.0.1 传进来"
BUILD_NUM="${BUILD_NUM:-$(date +%Y%m%d%H%M)}"
say "版本 $MARKETING_VERSION (build $BUILD_NUM)"

# ---------- 生成工程 ----------
say "xcodegen generate"
xcodegen generate >/dev/null

if [ "$KEEP_BUILD" -eq 0 ]; then
  rm -rf build-dev
fi

# ---------- 编译 ----------
say "编译 device/Release（不签名）"
xcodebuild \
  -project Melo.xcodeproj \
  -scheme Melo \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build-dev \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  build -quiet

APP=$(find build-dev/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)
[ -n "${APP:-}" ] || die "编译成功但找不到 .app"
say "APP = $APP"

BIN_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || echo Melo)
[ -f "$APP/$BIN_NAME" ] || die "找不到可执行文件 $APP/$BIN_NAME"

# 确认真的是 arm64（不是模拟器切片）
ARCHS=$(lipo -archs "$APP/$BIN_NAME" 2>/dev/null || echo unknown)
say "二进制架构: $ARCHS"
case "$ARCHS" in
  *arm64*) ;;
  *) die "产物里没有 arm64 切片，装不到真机" ;;
esac

# 确认 Info.plist 版本号确实被覆盖了（避免版本号对不上）
PLIST_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo "?")
say "包内版本: $PLIST_VER ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null || echo '?'))"

# ---------- 伪签 ----------
if [ "$HAVE_LDID" -eq 1 ]; then
  say "ldid 伪签主二进制"
  ldid -S "$APP/$BIN_NAME"
else
  say "没有 ldid，跳过伪签（TrollStore 安装不受影响；要伪签执行 brew install ldid）"
fi

# ---------- 打包 ----------
say "打包 IPA"
DIST="$REPO_DIR/dist"
mkdir -p "$DIST"
IPA="$DIST/Melo-v${MARKETING_VERSION}.B${BUILD_NUM}.ipa"
rm -rf Payload "$IPA"
mkdir Payload
cp -R "$APP" Payload/
rm -rf "Payload/$(basename "$APP")/_CodeSignature" 2>/dev/null || true
zip -qry "$IPA" Payload
rm -rf Payload
[ -s "$IPA" ] || die "IPA 生成失败"

# 结构自检
unzip -l "$IPA" | grep -q "Payload/$(basename "$APP")/$BIN_NAME" \
  || die "IPA 结构异常：里面没有 Payload/*.app 主二进制"

SIZE=$(wc -c < "$IPA" | tr -d ' ')
MD5=$(md5 -q "$IPA" 2>/dev/null || md5sum "$IPA" | awk '{print $1}')
say "完成: $IPA ($((SIZE / 1024)) KB)"

printf 'IPA_PATH=%s\nIPA_SIZE=%s\nIPA_MD5=%s\n' "$IPA" "$SIZE" "$MD5"
