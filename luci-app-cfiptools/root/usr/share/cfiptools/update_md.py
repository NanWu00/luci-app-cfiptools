#!/usr/bin/env python3
import argparse
import re
import sys
from datetime import datetime
from pathlib import Path

def get_default_readme() -> Path:
    # 兜底行为：如果没传参数，默认使用脚本同目录下的 README.MD
    return Path(__file__).resolve().parent / "README.MD"

def update_readme(file_path: Path) -> None:
    updated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    new_line = f"**本次更新**: {updated_at}"

    # 如果文件不存在，直接创建一份完整的默认模板
    if not file_path.exists():
        default_content = f"""# ⚡ Cloudflare 优选节点

{new_line}

这是由 OpenWrt 路由器 CF IP Tools 插件自动定时测速并推送的最新优选节点。

## 📄 节点文件说明
* **[best_ips.txt](./best_ips.txt)**: 满足速度阈值的高速节点（推荐配置此文件）。
* **[full_ips.txt](./full_ips.txt)**: 所有 TCP 测试连通的备用节点。

## ⏱️ 更新频率
由路由器根据设定的时间间隔自动执行并同步至此仓库。
"""
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(default_content, encoding="utf-8", newline="\n")
        print(f"Created new README at {file_path} with timestamp {updated_at}")
        return

    # 如果文件存在，使用强大的正则进行替换
    text = file_path.read_text(encoding="utf-8")
    
    # 精准匹配包含“本次更新”的行
    pattern = re.compile(r"^\s*(?:\*\*)?本次更新(?:\*\*)?\s*[:：].*$", re.MULTILINE)
    
    if pattern.search(text):
        # 命中目标：直接替换该行
        new_text = pattern.sub(new_line, text, count=1)
    else:
        # 未命中：智能寻找标题插入点
        lines = text.splitlines()
        insert_idx = 0
        for idx, line in enumerate(lines):
            if line.startswith("# "):
                insert_idx = idx + 1
                break
        
        # 跳过多余的空行，保持排版美观
        while insert_idx < len(lines) and not lines[insert_idx].strip():
            insert_idx += 1
            
        lines.insert(insert_idx, "")
        lines.insert(insert_idx + 1, new_line)
        lines.insert(insert_idx + 2, "")
        new_text = "\n".join(lines).strip() + "\n"

    # 写回文件
    file_path.write_text(new_text, encoding="utf-8", newline="\n")
    print(f"Updated README timestamp to {updated_at} in {file_path}")

def main() -> int:
    parser = argparse.ArgumentParser(description="Update README.MD timestamp.")
    parser.add_argument(
        "-f", "--file", 
        type=Path, 
        default=get_default_readme(),
        help="Path to the README file to update"
    )
    args = parser.parse_args()

    try:
        update_readme(args.file)
        return 0
    except Exception as e:
        print(f"ERROR: Failed to update README: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())