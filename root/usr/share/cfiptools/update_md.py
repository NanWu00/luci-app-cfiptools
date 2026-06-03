#!/usr/bin/env python3
from __future__ import annotations
from datetime import datetime
from pathlib import Path
import re

README_PATH = Path(__file__).resolve().parent / "README.MD"
updated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

if not README_PATH.exists():
    default_readme = f"""# ⚡ Cloudflare 优选节点

**本次更新**: {updated_at}

这是由 OpenWrt 路由器 CF IP Tools 插件自动定时测速并推送的最新优选节点。

## 📄 节点文件说明
* **[best_ips.txt](./best_ips.txt)**: 满足速度阈值的高速节点（推荐配置此文件）。
* **[full_ips.txt](./full_ips.txt)**: 所有 TCP 测试连通的备用节点。

## ⏱️ 更新频率
由路由器根据设定的时间间隔自动执行并同步至此仓库。
"""
    README_PATH.write_text(default_readme, encoding="utf-8", newline="\n")
    print(f"Created new README.MD with timestamp {updated_at}")
    raise SystemExit(0)

text = README_PATH.read_text(encoding="utf-8")
line_pattern = re.compile(r"^\s*(?:\*\*)?本次更新(?:\*\*)?\s*[:：].*$")
new_line = f"**本次更新**: {updated_at}"

lines = text.splitlines()
updated_lines = []
found = False
for line in lines:
    if line_pattern.match(line):
        if not found:
            updated_lines.append(new_line)
            found = True
        continue
    updated_lines.append(line)

if not found:
    insert_index = None
    for idx, line in enumerate(updated_lines):
        if line.strip().startswith("**更新频率**"):
            insert_index = idx + 1
            break
    if insert_index is None:
        for idx, line in enumerate(updated_lines):
            if line.startswith("# "):
                insert_index = idx + 1
                break
    if insert_index is None:
        updated_lines.append("")
        updated_lines.append(new_line)
    else:
        while insert_index < len(updated_lines) and updated_lines[insert_index].strip() == "":
            insert_index += 1
        updated_lines.insert(insert_index, "")
        updated_lines.insert(insert_index + 1, new_line)

text = "\n".join(updated_lines).rstrip() + "\n"
README_PATH.write_text(text, encoding="utf-8", newline="\n")
print(f"Updated README timestamp to {updated_at}")