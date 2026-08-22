#!/usr/bin/env python3
"""把中繼站呼叫紀錄（~/Library/Logs/learn-loop-calls.jsonl）裡模型寫過的每個 $…$ / $$…$$ 抽出來，一行一個。"""
import json, os, re

rows = [json.loads(l) for l in open(os.path.expanduser("~/Library/Logs/learn-loop-calls.jsonl"))]
seen = set()

def strings(v):
    if isinstance(v, str): yield v
    elif isinstance(v, dict):
        for x in v.values(): yield from strings(x)
    elif isinstance(v, list):
        for x in v: yield from strings(x)

for row in rows:
    for s in strings(row["result"]):
        s = re.sub(r"\$\$\s*\n([\s\S]*?)\n\s*\$\$", lambda m: "$$" + m.group(1).replace("\n", " ") + "$$", s)
        for m in re.finditer(r"\$\$([^$]+?)\$\$|\$([^$\n]+?)\$", s):
            f = (m.group(1) or m.group(2)).strip()
            if f and f not in seen:
                seen.add(f); print(f)
