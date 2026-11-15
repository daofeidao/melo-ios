#!/usr/bin/env bash
# mac-bootstrap-ssh.sh — 在 Mac 上跑一次，装好 Windows 的公钥 + 建好构建目录
#
# 用处：让 Windows 那边可以免密 ssh/scp 进来出包（不用每次输密码）。
# 用法（Mac 终端里，或用 UU 远程终端）：
#   bash mac-bootstrap-ssh.sh                       # 用脚本里内置的公钥
#   bash mac-bootstrap-ssh.sh "ssh-ed25519 AAAA... 备注"   # 换一把
#
# 注意：这个脚本不需要 sudo。开「远程登录」要在系统设置里点，或者自己 sudo。
set -euo pipefail

KEY="${1:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILYvl3EOcYaTHf02vEZh+51p+4VQij0fUlX/AtGN6CML wb-local-SZ}"

echo "==> 写入 ~/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

# 幂等：同一把钥匙不重复追加
if grep -qF "$(echo "$KEY" | awk '{print $2}')" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  echo "    已存在，跳过"
else
  printf '%s\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
  echo "    已追加"
fi

echo "==> 建构建目录"
mkdir -p "$HOME/melo-build/incoming" "$HOME/melo-sync"

echo "==> 检查远程登录"
if netstat -an 2>/dev/null | grep -q '\.22 .*LISTEN'; then
  echo "    sshd 已开启 ✅"
else
  echo "    sshd 未开启 ❌"
  echo "    去「系统设置 → 通用 → 共享 → 远程登录」打开（或 sudo systemsetup -setremotelogin on）"
fi

echo "==> 当前账户: $(id -un)"
echo "    Windows 侧配置写：\"user\": \"$(id -un)\""
for i in en0 en1; do
  ip=$(ipconfig getifaddr "$i" 2>/dev/null) && [ -n "$ip" ] && echo "    $i IP: $ip"
done
echo "==> 完成"
