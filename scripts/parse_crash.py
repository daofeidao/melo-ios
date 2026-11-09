#!/usr/bin/env python3
"""打印 .ips 崩溃报告的关键信息与出错线程的调用栈。

模拟器写出的 .ips 有两种形态：首行是 JSON 头，之后才是正文；
新版里 usedImages 的条目可能直接是整数，直接取 ["name"] 会抛异常。
"""

import json
import sys


def image_name(images, index):
    if isinstance(index, int) and 0 <= index < len(images):
        entry = images[index]
        if isinstance(entry, dict):
            return entry.get("name") or "?"
        if isinstance(entry, str):
            return entry
        return "#%d" % index
    return "?"


def main():
    if len(sys.argv) < 2:
        print("usage: parse_crash.py <file.ips>")
        return

    path = sys.argv[1]
    text = open(path, encoding="utf-8", errors="replace").read()
    _, _, rest = text.partition("\n")

    try:
        body = json.loads(rest)
    except Exception:
        print("(非 JSON 崩溃报告，前 400 字符如下)")
        print(text[:400])
        return

    exc = body.get("exception") or {}
    term = body.get("termination") or {}
    print("exception  :", exc.get("type"), exc.get("signal"), exc.get("subtype"))
    print("termination:", term.get("indicator"), "code=", term.get("code"))

    asi = body.get("asi")
    if asi:
        print("asi        :", asi)

    threads = body.get("threads") or []
    images = body.get("usedImages") or []
    faulting = body.get("faultingThread", 0)

    if isinstance(faulting, int) and 0 <= faulting < len(threads):
        thread = threads[faulting]
        print("thread     :", faulting, "| queue:", thread.get("queue"), "| name:", thread.get("name"))
        for frame in (thread.get("frames") or [])[:20]:
            symbol = frame.get("symbol") or ""
            print("   %-26s %s + %s" % (image_name(images, frame.get("imageIndex")), symbol, frame.get("imageOffset", 0)))
    else:
        print("faultingThread 越界:", faulting)


if __name__ == "__main__":
    main()
