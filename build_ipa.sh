#!/usr/bin/env bash
# build_ipa.sh — Mac 端通用 IPA 构建器（自动识别任意 Xcode 工程，免证书 + ldid 伪签）
#
# 设计目标：项目名 / Scheme / 目录结构每次都可能不同（AI 生成新项目），
#           所以这里不写死任何工程名，全部运行时从源码里探测：
#             1) 有 project.yml → 先 xcodegen generate；否则直接用现成 .xcodeproj/.xcworkspace
#             2) 自动找 .xcworkspace（优先）/ .xcodeproj
#             3) xcodebuild -list 自动提取 Scheme（优先与工程同名，否则取第一个）
#             4) 从产物的 Info.plist 读 CFBundleExecutable（伪签目标）和版本号（拼 IPA 名）
#
# 面向 2011 MacBook Pro（Sandy Bridge，无 AVX2）：Swift 前端必须 Xcode 14.x，15+ 会 SIGILL。
#
# 用法：
#   ./build_ipa.sh                          # 构建 ~/melo-sync
#   ./build_ipa.sh /path/to/repo            # 构建指定目录
#   ./build_ipa.sh --keep-build             # 复用上次 build-dev（快，但有陈旧产物风险）
#   MARKETING_VERSION=2.0.1 ./build_ipa.sh  # 覆盖版本号（默认读 project.yml 或产物 Info.plist）
#   BUILD_NUM=118 ./build_ipa.sh            # 覆盖构建号（默认时间戳）
#
# 产物：<repo>/dist/<AppName>-v<版本>.B<构建号>.ipa   （AppName 来自产物 .app，动态）
# 末行固定输出三行机器可读信息，供 Windows 端 mac_build.py 解析（不再靠猜文件名）：
#   IPA_PATH=...
#   IPA_SIZE=...
#   IPA_MD5=...
set -euo pipefail

# ---------- 工具 PATH ----------
# 这台 Mac 没有 Homebrew（github.com 被墙，brew 装不上），xcodegen/ldid 是手动放到
# ~/mac-tools/xcodegen/bin 和 ~/bin 的本地二进制。非交互 SSH 的 PATH 不含这些目录，
# 所以这里主动补上；已存在的目录才加，避免污染。
for _d in "$HOME/mac-tools/xcodegen/bin" "$HOME/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  if [ -d "$_d" ]; then
    case ":$PATH:" in
      *":$_d:"*) ;;
      *) PATH="$_d:$PATH" ;;
    esac
  fi
done
export PATH

# ---------- 参数 ----------
REPO_DIR=""
KEEP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --keep-build) KEEP_BUILD=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) echo "未知参数: $arg" >&2; exit 2 ;;
    *) REPO_DIR="$arg" ;;
  esac
done
REPO_DIR="${REPO_DIR:-$HOME/melo-sync}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$REPO_DIR" ] || die "目录不存在: $REPO_DIR"
cd "$REPO_DIR"

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

command -v ldid >/dev/null 2>&1 && HAVE_LDID=1 || HAVE_LDID=0

# ---------- 生成工程（仅当带 project.yml） ----------
if [ -f project.yml ]; then
  command -v xcodegen >/dev/null 2>&1 || die "有 project.yml 但缺 xcodegen：brew install xcodegen"
  say "检测到 project.yml，xcodegen generate"
  xcodegen generate >/dev/null
else
  say "没有 project.yml，使用仓库自带的 Xcode 工程"
fi

# ---------- 动态发现工程 ----------
WS=$(find . -maxdepth 2 -type d -name '*.xcworkspace' ! -name 'Pods.xcworkspace' 2>/dev/null | head -1 || true)
PROJ=""
if [ -n "${WS:-}" ]; then
  PROJ="$WS"; LIST_FLAG="-workspace"
else
  PB=$(find . -maxdepth 2 -type d -name '*.xcodeproj' 2>/dev/null | head -1 || true)
  [ -n "${PB:-}" ] || die "没找到任何 .xcworkspace / .xcodeproj（也没有 project.yml 可生成）"
  PROJ="$PB"; LIST_FLAG="-project"
fi
PROJ_NAME=$(basename "$PROJ")
PROJ_NAME="${PROJ_NAME%.*}"
say "工程: $PROJ  ($LIST_FLAG)"

# ---------- 动态提取 Scheme ----------
LIST_RAW=$(xcodebuild -list $LIST_FLAG "$PROJ" 2>/dev/null || true)
ALL_SCHEMES=$(printf '%s\n' "$LIST_RAW" | awk '/Schemes:/{f=1;next} f&&NF{gsub(/^[ \t]+|[ \t]+$/,"");print}')
[ -n "${ALL_SCHEMES:-}" ] || die "xcodebuild -list 没提取到 Scheme，原始输出：\n$LIST_RAW"
SCHEME=$(printf '%s\n' "$ALL_SCHEMES" | grep -Fx "$PROJ_NAME" | head -1 || true)
[ -n "${SCHEME:-}" ] || SCHEME=$(printf '%s\n' "$ALL_SCHEMES" | head -1)
say "Scheme: $SCHEME"

# ---------- 版本号 ----------
if [ -z "${MARKETING_VERSION:-}" ] && [ -f project.yml ]; then
  MARKETING_VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([0-9]+(\.[0-9]+)*)".*/\1/' || true)
fi
BUILD_NUM="${BUILD_NUM:-$(date +%Y%m%d%H%M)}"
say "版本 ${MARKETING_VERSION:-<待编译后从产物读取>} (build $BUILD_NUM)"

if [ "$KEEP_BUILD" -eq 0 ]; then
  rm -rf build-dev
fi

# ---------- 编译（device / Release / 不签名） ----------
say "编译 device/Release（不签名）"
COMMON_ARGS=(
  $LIST_FLAG "$PROJ"
  -scheme "$SCHEME"
  -configuration Release
  -destination 'generic/platform=iOS'
  -derivedDataPath build-dev
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CURRENT_PROJECT_VERSION="$BUILD_NUM"
)
# macOS 自带 bash 3.2，空数组在 set -u 下会报错，所以分两支写
if [ -n "${MARKETING_VERSION:-}" ]; then
  xcodebuild "${COMMON_ARGS[@]}" MARKETING_VERSION="$MARKETING_VERSION" build -quiet
else
  xcodebuild "${COMMON_ARGS[@]}" build -quiet
fi

# ---------- 找 .app（动态） ----------
APP=$(find build-dev/Build/Products/Release-iphoneos -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -1 || true)
if [ -z "${APP:-}" ]; then
  APP=$(find build-dev -type d -name '*.app' 2>/dev/null | grep -v '\.app/' | head -1 || true)
fi
[ -n "${APP:-}" ] || die "编译成功但找不到 .app"
APP_NAME=$(basename "$APP" .app)
say "APP = $APP  (name=$APP_NAME)"

BIN_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || echo "$APP_NAME")
[ -f "$APP/$BIN_NAME" ] || die "找不到可执行文件 $APP/$BIN_NAME"

ARCHS=$(lipo -archs "$APP/$BIN_NAME" 2>/dev/null || echo unknown)
say "二进制架构: $ARCHS"
case "$ARCHS" in
  *arm64*) ;;
  *) die "产物里没有 arm64 切片，装不到真机" ;;
esac

if [ -z "${MARKETING_VERSION:-}" ]; then
  MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo "1.0")
fi
PLIST_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo "?")
say "包内版本: $PLIST_VER ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null || echo '?'))"

# ---------- 伪签（免开发者账号，供 TrollStore） ----------
if [ "$HAVE_LDID" -eq 1 ]; then
  say "ldid 伪签主二进制"
  ldid -S "$APP/$BIN_NAME"
else
  say "没有 ldid，跳过伪签（TrollStore 安装不受影响；要伪签执行 brew install ldid）"
fi

# ---------- 打包 IPA ----------
say "打包 IPA"
DIST="$REPO_DIR/dist"
mkdir -p "$DIST"
IPA="$DIST/${APP_NAME}-v${MARKETING_VERSION}.B${BUILD_NUM}.ipa"
rm -rf Payload "$IPA"
mkdir Payload
cp -R "$APP" Payload/
rm -rf "Payload/$(basename "$APP")/_CodeSignature" 2>/dev/null || true
zip -qry "$IPA" Payload
rm -rf Payload
[ -s "$IPA" ] || die "IPA 生成失败"

unzip -l "$IPA" | grep -q "Payload/$(basename "$APP")/$BIN_NAME" \
  || die "IPA 结构异常：里面没有 Payload/*.app 主二进制"

SIZE=$(wc -c < "$IPA" | tr -d ' ')
MD5=$(md5 -q "$IPA" 2>/dev/null || md5sum "$IPA" | awk '{print $1}')
say "完成: $IPA ($((SIZE / 1024)) KB)"

printf 'IPA_PATH=%s\nIPA_SIZE=%s\nIPA_MD5=%s\n' "$IPA" "$SIZE" "$MD5"
