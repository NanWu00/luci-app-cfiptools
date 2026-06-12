#!/usr/bin/env python3
import argparse
import re
import sys
from datetime import datetime
from pathlib import Path

def get_default_readme() -> Path:
    return Path(__file__).resolve().parent / "README.MD"

def update_readme(file_path: Path) -> None:
    updated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    new_line = f"**本次更新**: {updated_at}"

    if not file_path.exists():
        default_content = f"""# ⚡ Cloudflare 优选节点\n\n{new_line}\n\n这是由 OpenWrt 路由器 CF IP Tools 插件自动定时测速并推送的最新优选节点。\n\n## 📄 节点文件说明\n* **[best_ips.txt](./best_ips.txt)**: 满足速度阈值的高速节点（推荐配置此文件）。\n* **[full_ips.txt](./full_ips.txt)**: 所有 TCP 测试连通的备用节点。\n\n## ⏱️ 更新频率\n由路由器根据设定的时间间隔自动执行并同步至此仓库。\n"""
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(default_content, encoding="utf-8", newline="\n")
        print(f"Created new README at {file_path} with timestamp {updated_at}")
        return

    text = file_path.read_text(encoding="utf-8")
    pattern = re.compile(r"^\s*(?:\*\*)?本次更新(?:\*\*)?\s*[:：].*$", re.MULTILINE)
    
    if pattern.search(text):
        new_text = pattern.sub(new_line, text, count=1)
    else:
        lines = text.splitlines()
        insert_idx = 0
        for idx, line in enumerate(lines):
            if line.startswith("# "):
                insert_idx = idx + 1
                break
        while insert_idx < len(lines) and not lines[insert_idx].strip():
            insert_idx += 1
        lines.insert(insert_idx, "")
        lines.insert(insert_idx + 1, new_line)
        lines.insert(insert_idx + 2, "")
        new_text = "\n".join(lines).strip() + "\n"

    file_path.write_text(new_text, encoding="utf-8", newline="\n")
    print(f"Updated README timestamp to {updated_at} in {file_path}")

def main() -> int:
    parser = argparse.ArgumentParser(description="Update README.MD timestamp.")
    parser.add_argument("-f", "--file", type=Path, default=get_default_readme())
    args = parser.parse_args()
    try:
        update_readme(args.file)
        return 0
    except Exception as e:
        print(f"ERROR: Failed to update README: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())