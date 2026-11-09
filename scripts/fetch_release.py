#!/usr/bin/env python3
"""从 GitHub Release 取产物，带断点续传。

本机到 GitHub 的下载链路会在大文件上中途断流（表现为文件只有一半大小），
gh release download 不做续传，所以这里自己循环 curl -C - 直到字节数对齐。

    python scripts/fetch_release.py build-15 D:\\wb\\downloads\\melo
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

REPO = "daofeidao/melo-ios"


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("dest")
    parser.add_argument("--rounds", type=int, default=8)
    args = parser.parse_args()

    dest = pathlib.Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    assets = json.loads(gh("release", "view", args.tag, "-R", REPO, "--json", "assets"))["assets"]
    token = gh("auth", "token").strip()

    failures = []
    for asset in assets:
        name = asset["name"]
        want = asset["size"]
        # gh 的 release JSON 里 url 是网页地址，apiUrl 才是会 302 到签名地址的接口
        api_url = asset.get("apiUrl") or asset["url"]
        target = dest / name

        # 先换成签名跳转地址：带 Authorization 对 S3 发 Range 请求会返回 400，
        # 续传必须打在签名 URL 上。
        signed = subprocess.run(
            [
                "curl", "-sS", "--max-time", "30", "-o", os.devnull, "-w", "%{redirect_url}",
                "-H", f"Authorization: Bearer {token}",
                "-H", "Accept: application/octet-stream",
                api_url,
            ],
            capture_output=True, text=True,
        ).stdout.strip()

        if not signed:
            print(f"BAD {name:34s} 拿不到签名地址")
            failures.append(name)
            continue

        for _ in range(args.rounds):
            have = target.stat().st_size if target.exists() else 0
            if have == want:
                break
            # 必须给 --max-time：连接卡死时 curl 会一直挂着，整个取件流程就停住了
            subprocess.run(
                ["curl", "-sS", "-L", "--max-time", "90", "-C", "-", "-o", str(target), signed],
                capture_output=True,
            )

        have = target.stat().st_size if target.exists() else 0
        status = "OK " if have == want else "BAD"
        print(f"{status} {name:34s} {have}/{want}")
        if have != want:
            failures.append(name)

    if failures:
        sys.exit(f"未完整下载：{failures}")
    print(f"\n全部完整，目录：{dest}")


if __name__ == "__main__":
    main()
