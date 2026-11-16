#!/usr/bin/env python3
"""兼容入口：转发到用户级技能 mac-ipa-build 的驱动器。

真正的实现（也是唯一的实现）：
    ~/.workbuddy/skills/mac-ipa-build/scripts/mac_build.py

保留本文件是为了让 `python scripts/mac_build.py` 这条老命令继续可用，
并且不带 --repo 时自动指向本仓库根目录。

用法：
    python scripts/mac_build.py                 # 构建本工程 + 自动发邮件
    python scripts/mac_build.py --no-email
    python scripts/mac_build.py --version 2.0.9 --build 118
    python scripts/mac_build.py --probe
"""
import runpy
import sys
from pathlib import Path

SKILL = Path.home() / ".workbuddy" / "skills" / "mac-ipa-build" / "scripts" / "mac_build.py"
REPO = Path(__file__).resolve().parent.parent

if not SKILL.exists():
    sys.exit(
        f"找不到技能脚本：{SKILL}\n"
        "请确认用户级技能 mac-ipa-build 已安装（~/.workbuddy/skills/mac-ipa-build/）。"
    )

argv = sys.argv[1:]
has_repo = any(a == "--repo" or a.startswith("--repo=") for a in argv)
if not has_repo:
    argv = ["--repo", str(REPO)] + argv

sys.argv = [str(SKILL)] + argv
runpy.run_path(str(SKILL), run_name="__main__")
