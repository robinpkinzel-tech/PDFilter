#!/usr/bin/env python3
"""Druckt die wichtigsten Teile eines macOS-Absturzberichts (.ips) lesbar aus."""
import json, sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
parts = raw.split("\n", 1)
body = json.loads(parts[1] if len(parts) > 1 else parts[0])
print("procName:", body.get("procName"))
print("exception:", body.get("exception"))
print("termination:", body.get("termination"))
for key in ("asiBacktraces", "asi", "lastExceptionBacktrace"):
    if body.get(key):
        print(key, ":", json.dumps(body.get(key), ensure_ascii=False)[:3000])
ft = body.get("faultingThread", 0)
threads = body.get("threads", [])
imgs = body.get("usedImages", [])
if threads:
    th = threads[ft]
    print("--- faulting thread", ft, th.get("name"), th.get("queue"))
    for fr in th.get("frames", [])[:45]:
        img = imgs[fr["imageIndex"]] if fr.get("imageIndex", -1) < len(imgs) else {}
        print(f'{img.get("name")}  {fr.get("symbol")} +{fr.get("symbolLocation")}  {fr.get("sourceFile","")}:{fr.get("sourceLine","")}')
