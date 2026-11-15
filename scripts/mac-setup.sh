#!/usr/bin/env bash
# mac-setup.sh — 在 Mac 上跑一次，体检 + 补齐本地出包环境
#
# 用法（在 Mac 终端里）：
#   bash mac-setup.sh
#
# 它只做三件不破坏现状的事：
#   1) 打印机型 / CPU 指令集 / macOS 版本（判断能不能用 Xcode 14）
#   2) 检查并安装 xcodegen、ldid（走 brew，已装则跳过）
#   3) 打印 SSH 是否开启、当前用户名与局域网 IP，供 Windows 侧填写配置
set -uo pipefail

say() { printf '==> %s\n' "$*"; }
line() { printf '%s\n' '------------------------------------------------------------'; }

line
say "系统与硬件"
say "  机型: $(sysctl -n hw.model 2>/dev/null)"
say "  CPU : $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
say "  内存: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
say "  系统: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
CPU_FEAT=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null || true)
if echo "$CPU_FEAT" | grep -qi AVX2; then
  say "  指令集: 有 AVX2 → Xcode 15/16 可用"
else
  say "  指令集: 无 AVX2 → Xcode 只能用 14.x（15+ 会 SIGILL 崩溃）"
fi
line

say "Xcode"
if command -v xcodebuild >/dev/null 2>&1; then
  say "  当前: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  say "  路径: $(xcode-select -p 2>/dev/null)"
else
  say "  未安装，或 xcode-select 没指到 Xcode（只装了 Command Line Tools）"
fi
ls -d /Applications/Xcode*.app 2>/dev/null | while read -r app; do
  say "  已装: $app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null))"
done
line

say "依赖工具"
if command -v brew >/dev/null 2>&1; then
  for tool in xcodegen ldid; do
    if command -v "$tool" >/dev/null 2>&1; then
      say "  $tool: 已装"
    else
      say "  $tool: 未装，开始 brew install $tool"
      brew install "$tool" || say "  $tool 安装失败，稍后手动执行 brew install $tool"
    fi
  done
else
  say "  没有 Homebrew，请先装：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi
line

say "远程登录 (SSH)"
if netstat -an 2>/dev/null | grep -q '\.22 .*LISTEN'; then
  say "  sshd: 已开启 ✅"
else
  say "  sshd: 未开启 ❌  去「系统设置 → 通用 → 共享 → 远程登录」打开"
fi
say "  用户名: $(id -un)"
say "  主机名: $(scutil --get LocalHostName 2>/dev/null).local"
for i in en0 en1 en5 bridge0; do
  ip=$(ipconfig getifaddr "$i" 2>/dev/null) && [ -n "$ip" ] && say "  $i IP: $ip"
done
line

say "构建目录"
mkdir -p "$HOME/melo-build/incoming" "$HOME/melo-sync"
say "  暂存: $HOME/melo-build/incoming"
say "  源码: $HOME/melo-sync"
line
say "体检结束。把「用户名」和「IP」告我，或直接在 UU 里给 22 端口做端口映射，我就能从 Windows 侧驱动构建。"
