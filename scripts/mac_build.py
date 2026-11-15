#!/usr/bin/env python3
"""mac_build.py — 从 Windows 驱动 Mac 本地 Xcode 出 IPA。

流程（全程走 SSH，不依赖 Mac 访问 GitHub）：
    打包源码  →  scp 上传  →  Mac 上跑 build_ipa.sh  →  scp 拉回 IPA

第一次使用：
    python scripts/mac_build.py --setup        # 上传并运行 mac-setup.sh，打印机型/工具/SSH 体检
    （体检打印出的「用户名」和「端口」填进 scripts/mac-build.json）

日常使用：
    python scripts/mac_build.py                # 版本号自动读 project.yml
    python scripts/mac_build.py --version 2.0.1 --build 118
    python scripts/mac_build.py --probe        # 只测连通性
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(__file__).resolve().parent / "mac-build.json"
DEFAULT_OUT = Path("D:/wb/downloads/melo")

# 只打包编译真正需要的东西；.git / build* / dist 一律不进包，保证 Mac 侧干净、快
PACK_INCLUDE = ["Sources", "Resources", "Localization", "project.yml", "build_ipa.sh"]
PACK_EXTRA_FILES = ["scripts/mac-setup.sh"]

C_OK, C_WARN, C_ERR, C_DIM, C_END = "\033[32m", "\033[33m", "\033[31m", "\033[90m", "\033[0m"


def say(msg: str) -> None:
    print(f"{C_DIM}==>{C_END} {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"{C_OK}✓{C_END} {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"{C_WARN}!{C_END} {msg}", flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"{C_ERR}✗ {msg}{C_END}", file=sys.stderr, flush=True)
    sys.exit(code)


# ---------------------------------------------------------------- 配置
def load_config(args) -> dict:
    cfg = {
        "host": "127.0.0.1",
        "port": 22,
        "user": os.environ.get("USERNAME", ""),
        "remoteStage": "~/melo-build/src",
        "remoteIncoming": "~/melo-build/incoming",
        "outDir": str(DEFAULT_OUT),
        "identity": "",
    }
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
        except json.JSONDecodeError as exc:
            die(f"{CONFIG_PATH} 不是合法 JSON：{exc}")

    if args.host:
        cfg["host"] = args.host
    if args.port:
        cfg["port"] = int(args.port)
    if args.user:
        cfg["user"] = args.user
    if args.out:
        cfg["outDir"] = args.out

    if not cfg.get("user"):
        die(
            "还没有 Mac 的登录用户名。\n"
            "  1) 先在 Mac 上跑一次：bash scripts/mac-setup.sh（会打印「用户名」与 IP）\n"
            "  2) 然后把结果填进 scripts/mac-build.json：\n"
            f'     {{"host": "127.0.0.1", "port": 10022, "user": "<用户名>"}}\n'
            f"  配置文件路径：{CONFIG_PATH}"
        )
    return cfg


def ssh_base(cfg: dict) -> list[str]:
    cmd = [
        "ssh",
        "-p", str(cfg["port"]),
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=12",
        "-o", "ServerAliveInterval=20",
    ]
    if cfg.get("identity"):
        cmd += ["-i", str(Path(cfg["identity"]).expanduser())]
    return cmd


def scp_base(cfg: dict) -> list[str]:
    cmd = [
        "scp",
        "-P", str(cfg["port"]),
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=12",
    ]
    if cfg.get("identity"):
        cmd += ["-i", str(Path(cfg["identity"]).expanduser())]
    return cmd


def target(cfg: dict) -> str:
    return f'{cfg["user"]}@{cfg["host"]}'


def run_streaming(cmd: list[str], title: str) -> int:
    """边跑边打印，长构建不至于看起来卡死。"""
    if title:
        say(title)
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace"
    )
    assert proc.stdout
    for line in proc.stdout:
        line = line.rstrip("\n")
        if line.startswith("==>"):
            print(f"   {C_DIM}{line}{C_END}", flush=True)
        elif line.startswith(("IPA_PATH=", "IPA_SIZE=", "IPA_MD5=")):
            print(f"   {C_OK}{line}{C_END}", flush=True)
        elif "error:" in line.lower() or "ERROR" in line:
            print(f"   {C_ERR}{line}{C_END}", flush=True)
        else:
            print(f"   {line}", flush=True)
    proc.wait()
    return proc.returncode


# ---------------------------------------------------------------- 版本
def read_version() -> str:
    text = (REPO / "project.yml").read_text(encoding="utf-8")
    for line in text.splitlines():
        if "MARKETING_VERSION" in line:
            parts = line.split('"')
            if len(parts) >= 2:
                return parts[1]
    die("project.yml 里读不到 MARKETING_VERSION，请用 --version 指定")


# ---------------------------------------------------------------- 打包
def make_tarball(path: Path) -> int:
    count = 0
    with tarfile.open(path, "w:gz") as tar:
        for rel in PACK_INCLUDE:
            src = REPO / rel
            if not src.exists():
                warn(f"跳过不存在的 {rel}")
                continue
            for item in sorted(src.rglob("*")) if src.is_dir() else [src]:
                if not item.is_file():
                    continue
                parts = item.relative_to(REPO).parts
                if any(p in (".git", "build", "build-dev", "build-sim", "dist", "__pycache__") for p in parts):
                    continue
                tar.add(item, arcname=str(item.relative_to(REPO)))
                count += 1
        for rel in PACK_EXTRA_FILES:
            src = REPO / rel
            if src.exists():
                tar.add(src, arcname=str(src.relative_to(REPO)))
                count += 1
    return count


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- 远程
def remote_check(cfg: dict) -> None:
    say(f"测试连接 {target(cfg)}:{cfg['port']}")
    code = run_streaming(
        ssh_base(cfg) + [target(cfg), "uname -sm; id -un; command -v xcodebuild >/dev/null && xcodebuild -version | head -1 || echo 'NO_XCODE'"],
        "",
    )
    if code != 0:
        die(
            "连不上 Mac。逐项自查：\n"
            "  1) Mac 已解锁到桌面、网络在线、UU 会话已连接\n"
            "  2) Mac 上「系统设置 → 通用 → 共享 → 远程登录」已打开\n"
            "  3) UU 里给 Mac 的 22 端口做了端口映射，并把映射出来的地址填进 mac-build.json\n"
            "  4) Windows 的公钥已追加到 Mac 的 ~/.ssh/authorized_keys\n"
            f"  5) 手工验证：ssh -p {cfg['port']} {target(cfg)} 'echo hi'"
        )


def safe_remote_dir(path: str, must_end: str) -> str:
    """远程 rm -rf 前的护栏：只允许删我们自己的构建目录。"""
    p = path.rstrip("/")
    if not p.endswith(must_end):
        die(f"拒绝操作可疑路径 {path}（必须以 {must_end} 结尾）")
    return p


def do_setup(cfg: dict) -> None:
    remote_check(cfg)
    tmp = Path(tempfile.mkdtemp(prefix="melo-setup-"))
    script = REPO / "scripts" / "mac-setup.sh"
    if not script.exists():
        die(f"缺 {script}")
    dest = f'{target(cfg)}:{cfg["remoteIncoming"]}/mac-setup.sh'
    Path(tmp, "mac-setup.sh").write_bytes(script.read_bytes())

    say("上传 mac-setup.sh")
    run_streaming(scp_base(cfg) + [str(Path(tmp, "mac-setup.sh")), dest], "")
    say("在 Mac 上执行体检")
    code = run_streaming(
        ssh_base(cfg) + [target(cfg), f'mkdir -p {cfg["remoteIncoming"]} && bash {cfg["remoteIncoming"]}/mac-setup.sh'],
        "",
    )
    shutil.rmtree(tmp, ignore_errors=True)
    if code != 0:
        die("体检脚本返回非 0，看上面输出")


def do_build(cfg: dict, version: str, build_num: str) -> Path:
    remote_check(cfg)

    tmpdir = Path(tempfile.mkdtemp(prefix="melo-src-"))
    tarball = tmpdir / "melo-src.tgz"
    say("打包源码")
    n = make_tarball(tarball)
    ok(f"{n} 个文件，{tarball.stat().st_size / 1024:.0f} KB")

    stage = safe_remote_dir(cfg["remoteStage"], "/melo-build/src")
    incoming = cfg["remoteIncoming"].rstrip("/")
    remote_tar = f"{incoming}/melo-src.tgz"

    say("上传到 Mac")
    run_streaming(scp_base(cfg) + [str(tarball), f"{target(cfg)}:{remote_tar}"], "")

    say("解包并编译")
    remote_cmd = f"""set -e
mkdir -p {incoming} {stage}
rm -rf {stage}
mkdir -p {stage}
tar -xzf '{remote_tar}' -C {stage}
chmod +x '{stage}/build_ipa.sh'
cd '{stage}'
MARKETING_VERSION={shlex.quote(version)} BUILD_NUM={shlex.quote(build_num)} bash build_ipa.sh '{stage}'
"""
    code = run_streaming(ssh_base(cfg) + [target(cfg), remote_cmd], "")
    shutil.rmtree(tmpdir, ignore_errors=True)
    if code != 0:
        die(
            "Mac 侧编译失败（退出码 %d）。常见原因：\n"
            "  · Xcode 版本不对（这台 2011 机器必须 14.x，15+ 会 SIGILL）\n"
            "  · 缺 xcodegen / ldid：在 Mac 上 brew install xcodegen ldid\n"
            "  · 磁盘满：rm -rf ~/melo-build/src/build-dev 后重试" % code
        )

    remote_ipa = f"{stage}/dist/Melo-v{version}.B{build_num}.ipa"
    out_dir = Path(cfg["outDir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    local_ipa = out_dir / posixpath.basename(remote_ipa)

    say("拉回 IPA")
    run_streaming(scp_base(cfg) + [f"{target(cfg)}:{remote_ipa}", str(local_ipa)], "")
    if not local_ipa.exists() or local_ipa.stat().st_size == 0:
        die(f"下载失败或文件为空：{local_ipa}")
    ok(f"{local_ipa}  ({local_ipa.stat().st_size / 1024:.0f} KB, md5 {md5_file(local_ipa)})")
    return local_ipa


# ---------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description="从 Windows 驱动 Mac 出 IPA")
    ap.add_argument("--setup", action="store_true", help="只做 Mac 环境体检")
    ap.add_argument("--probe", action="store_true", help="只测 SSH 连通性")
    ap.add_argument("--version", help="版本号，默认读 project.yml")
    ap.add_argument("--build", help="构建号，默认本地时间戳")
    ap.add_argument("--host")
    ap.add_argument("--port", type=int)
    ap.add_argument("--user")
    ap.add_argument("--out", help=f"IPA 存放目录，默认 {DEFAULT_OUT}")
    args = ap.parse_args()

    if not shutil.which("ssh") or not shutil.which("scp"):
        die("本机找不到 ssh / scp（Windows 设置 → 应用 → 可选功能 → OpenSSH 客户端）")

    cfg = load_config(args)

    if args.setup:
        do_setup(cfg)
        return 0
    if args.probe:
        remote_check(cfg)
        ok("连通性正常")
        return 0

    version = args.version or read_version()
    build_num = args.build or time.strftime("%m%d%H%M")
    print(f"\n{C_DIM}Melo {version} (build {build_num}) → {target(cfg)}:{cfg['port']}{C_END}\n")

    ipa = do_build(cfg, version, build_num)
    print(f"\n{C_OK}完成{C_END}  {ipa}")
    print(f"{C_DIM}下一步：发给自己的那封邮件 → python send_ipa.py \"{ipa}\" --to 13086848965@126.com{C_END}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
