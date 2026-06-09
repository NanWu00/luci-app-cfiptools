#!/usr/bin/env python3
import argparse
import asyncio
import heapq
import os
import shutil
import sys
import time
import ssl
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

DEFAULT_INPUT_FILE = Path("ips.txt")
DEFAULT_INPUT_URL = "https://zip.cm.edu.kg/all.txt"
DEFAULT_INPUT_DOWNLOAD_TIMEOUT = 30.0
DEFAULT_BEST_OUTPUT_FILE = Path("best_ips.txt")
DEFAULT_FULL_OUTPUT_FILE = Path("full_ips.txt")

DEFAULT_TCP_TIMEOUT = 1.5
DEFAULT_TCP_WORKERS = 200
DEFAULT_SPEED_TIMEOUT = 6.0
DEFAULT_SPEED_PROCESS_BUFFER = 8.0
DEFAULT_SPEED_WORKERS = 5
DEFAULT_MIN_SPEED_MBPS = 16
DEFAULT_TOP_PER_REGION = 5

SPEED_DOMAIN = "speed.cloudflare.com"
SPEED_PATH = "/__down"
SPEED_BYTES = 2 * 1024 * 1024
DEFAULT_FAST_LABEL = "优选高速"

REGION_EMOJIS = {
    "HK": "🇭🇰", "TW": "🇹🇼", "SG": "🇸🇬", "JP": "🇯🇵",
    "KR": "🇰🇷", "US": "🇺🇸", "GB": "🇬🇧", "UK": "🇬🇧",
    "FR": "🇫🇷", "DE": "🇩🇪", "NL": "🇳🇱", "RU": "🇷🇺",
    "IN": "🇮🇳", "AU": "🇦🇺", "CA": "🇨🇦", "BR": "🇧🇷",
    "ZA": "🇿🇦", "KG": "🇰🇬", "CN": "🇨🇳", "MO": "🇲🇴",
    "MY": "🇲🇾", "TH": "🇹🇭", "VN": "🇻🇳", "PH": "🇵🇭"
}

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

print_lock = asyncio.Lock()

# 仅下载测速复用 SSL 上下文，TCP 握手不需要
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE

def parse_bool(value: str) -> bool:
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}: return True
    if text in {"0", "false", "no", "off"}: return False
    raise ValueError(f"invalid boolean value: {value}")

def strip_region_number(region: str) -> str:
    base, sep, suffix = region.rpartition("_")
    if sep and base and suffix.isdigit(): return base
    return region

@dataclass(frozen=True)
class AppConfig:
    input_file: Path
    full_output_file: Path
    best_output_file: Path
    tcp_timeout: float
    tcp_workers: int
    speed_timeout: float
    speed_process_buffer: float
    speed_workers: int
    min_speed_mbps: float
    max_latency_ms: float
    strict_tcp_count: int
    speed_test_count: int
    top_per_region: int
    verbose: bool
    numbered_regions: bool
    show_latency: bool
    show_mbps: bool
    fast_label: str
    input_url: str

@dataclass(frozen=True)
class Node:
    ip: str
    port: int
    region: str
    @property
    def raw(self) -> str: return f"{self.ip}:{self.port}#{self.region}"

@dataclass(frozen=True)
class TcpResult:
    node: Node
    latency_ms: float

@dataclass(frozen=True)
class SpeedResult:
    node: Node
    latency_ms: float
    speed_mbps: float
    is_fast: bool

def parse_args() -> AppConfig:
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--input", type=Path, default=DEFAULT_INPUT_FILE)
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_FULL_OUTPUT_FILE)
    parser.add_argument("--best-output", type=Path, default=DEFAULT_BEST_OUTPUT_FILE)
    parser.add_argument("--tcp-timeout", type=float, default=DEFAULT_TCP_TIMEOUT)
    parser.add_argument("--tcp-workers", type=int, default=DEFAULT_TCP_WORKERS)
    parser.add_argument("--speed-timeout", type=float, default=DEFAULT_SPEED_TIMEOUT)
    parser.add_argument("--speed-process-buffer", type=float, default=DEFAULT_SPEED_PROCESS_BUFFER)
    parser.add_argument("--speed-workers", type=int, default=DEFAULT_SPEED_WORKERS)
    parser.add_argument("--min-speed", type=float, default=DEFAULT_MIN_SPEED_MBPS)
    parser.add_argument("--max-latency", type=float, default=0.0)
    parser.add_argument("--strict-tcp-count", type=int, default=0)
    parser.add_argument("--speed-count", type=int, default=1)
    parser.add_argument("--top", type=int, default=DEFAULT_TOP_PER_REGION)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--numbered", dest="numbered_regions", action="store_true", default=False)
    parser.add_argument("--show-latency", type=str, default="1")
    parser.add_argument("--show-mbps", type=str, default="0")
    parser.add_argument("--fast-label", type=str, default=DEFAULT_FAST_LABEL)
    parser.add_argument("--input-url", type=str, default=DEFAULT_INPUT_URL)
    args = parser.parse_args()

    return AppConfig(
        input_file=args.input, full_output_file=args.output, best_output_file=args.best_output,
        tcp_timeout=args.tcp_timeout, tcp_workers=args.tcp_workers, speed_timeout=args.speed_timeout,
        speed_process_buffer=args.speed_process_buffer, speed_workers=args.speed_workers,
        min_speed_mbps=args.min_speed, max_latency_ms=args.max_latency, strict_tcp_count=args.strict_tcp_count,
        speed_test_count=args.speed_count, top_per_region=args.top, verbose=args.verbose,
        numbered_regions=args.numbered_regions, show_latency=parse_bool(args.show_latency),
        show_mbps=parse_bool(args.show_mbps), fast_label=args.fast_label, input_url=args.input_url
    )

def parse_node(line: str) -> Node | None:
    text = line.strip()
    if not text or text.startswith("#") or "#" not in text: return None
    address, region = (part.strip() for part in text.split("#", 1))
    if not address or not region or ":" not in address: return None
    ip, port_text = (part.strip() for part in address.rsplit(":", 1))
    try: port = int(port_text)
    except ValueError: return None
    if not ip or not 1 <= port <= 65535: return None
    return Node(ip=ip, port=port, region=strip_region_number(region))

def load_nodes(path: Path) -> list[Node]:
    if not path.exists(): raise FileNotFoundError(f"input file not found: {path}")
    nodes, seen = [], set()
    with path.open("r", encoding="utf-8-sig") as file:
        for line in file:
            node = parse_node(line)
            if node and node not in seen:
                seen.add(node); nodes.append(node)
    return nodes

def positive_worker_count(req: int, total: int) -> int: return max(1, min(max(1, req), max(1, total)))

def print_progress(task_name: str, completed: int, total: int, bar_length: int = 30) -> None:
    if total <= 0: return
    percent = completed / total
    filled = int(bar_length * percent)
    bar = '█' * filled + '░' * (bar_length - filled)
    print(f"\r{task_name} [{bar}] {percent*100:.1f}% ({completed}/{total})", end='', flush=True)

def set_status(text: str) -> None:
    try:
        with open("/var/run/cfiptools.status", "w", encoding="utf-8") as f:
            f.write(f"{text}\n")
    except Exception:
        pass

# 恢复极速且存活率最高的纯净 TCP 握手测速
async def tcping(node: Node, timeout: float) -> float | None:
    start = time.perf_counter()
    writer = None
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(node.ip, node.port), timeout=timeout)
        return round((time.perf_counter() - start) * 1000, 2)
    except Exception: return None
    finally:
        if writer:
            writer.close()
            try: await writer.wait_closed()
            except Exception: pass

async def run_latency_tests(nodes: Sequence[Node], *, timeout: float, workers: int, verbose: bool) -> list[TcpResult]:
    set_status("TCP 海量初筛")
    print(f"--- [INFO] 开始第一轮 TCP 海量初筛 ---")
    
    queue, results = asyncio.Queue(), []
    total = len(nodes)
    task_name = "TCP初筛"
    completed = 0

    async def worker():
        nonlocal completed
        while True:
            node = await queue.get()
            if node is None:
                queue.task_done()
                return
            try:
                latency = await tcping(node, timeout)
                if latency is not None:
                    results.append(TcpResult(node=node, latency_ms=latency))
                    if verbose: print(f"\n[TCP-LAT] {node.raw} -> {latency} ms")
            except Exception as e:
                if verbose: print(f"\n[TCP Error] {node.raw} -> {e}")
            finally:
                async with print_lock:
                    completed += 1
                    print_progress(task_name, completed, total)
                queue.task_done()

    tasks = [asyncio.create_task(worker()) for _ in range(positive_worker_count(workers, len(nodes)))]
    for node in nodes: queue.put_nowait(node)
    for _ in tasks: queue.put_nowait(None)
    await queue.join()
    await asyncio.gather(*tasks)
    print()
    return results

def select_candidates(results: Iterable[TcpResult], top_per_region: int, max_latency: float) -> list[TcpResult]:
    groups = defaultdict(list)
    limit = max(1, top_per_region)
    for index, result in enumerate(results):
        if max_latency > 0 and result.latency_ms > max_latency:
            continue
        heap = groups[result.node.region]
        item = (-result.latency_ms, -index, result)
        if len(heap) < limit: heapq.heappush(heap, item)
        else: heapq.heappushpop(heap, item)
        
    candidates = [item[2] for region in sorted(groups) for item in groups[region]]
    candidates.sort(key=lambda item: item.latency_ms)
    return candidates

# 严苛过滤法则：纯粹的多次 TCP 握手验证，拒绝任何超时节点
async def verify_candidates_strict(candidates: Sequence[TcpResult], strict_count: int, timeout: float, workers: int, max_latency: float, verbose: bool) -> list[TcpResult]:
    valid_nodes = {cand.node: cand for cand in candidates}
    
    for i in range(strict_count):
        if not valid_nodes:
            break
            
        iteration_str = f"{i+1}/{strict_count}"
        status_msg = f"第{iteration_str}次 严格TCP复测淘汰"
        set_status(status_msg)
        print(f"--- [INFO] 开始 {status_msg} ---")
        
        queue = asyncio.Queue()
        current_targets = list(valid_nodes.values())
        total = len(current_targets)
        task_name = f"严格TCP复测({iteration_str})"
        completed = 0
        
        round_results = {}

        async def worker():
            nonlocal completed
            while True:
                cand = await queue.get()
                if cand is None:
                    queue.task_done()
                    return
                try:
                    latency = await tcping(cand.node, timeout)
                    round_results[cand.node] = latency
                    if verbose:
                        state = f"{latency} ms" if latency is not None else "超时/拒绝"
                        print(f"\n[STRICT-TCP] {cand.node.raw} -> {state}")
                except Exception as e:
                    if verbose: print(f"\n[STRICT-TCP Error] {cand.node.raw} -> {e}")
                finally:
                    async with print_lock:
                        completed += 1
                        print_progress(task_name, completed, total)
                    queue.task_done()

        tasks = [asyncio.create_task(worker()) for _ in range(positive_worker_count(workers, len(current_targets)))]
        for cand in current_targets: queue.put_nowait(cand)
        for _ in tasks: queue.put_nowait(None)
        await queue.join()
        await asyncio.gather(*tasks)
        print()
        
        survivors = {}
        for node, cand in valid_nodes.items():
            lat = round_results.get(node)
            if lat is None:
                if verbose: print(f"[-] 剔除 {node.raw} (原因: 本轮 TCP 握手无法连通)")
            elif max_latency > 0 and lat > max_latency:
                if verbose: print(f"[-] 剔除 {node.raw} (原因: 延迟 {lat}ms 超过设定最高值 {max_latency}ms)")
            else:
                survivors[node] = cand
                
        valid_nodes = survivors
        print(f"--- [INFO] 本轮 TCP 复测结束，剩余 {len(valid_nodes)} 个坚如磐石的节点 ---")

    return list(valid_nodes.values())

async def measure_speed_async(node: Node, timeout: float, process_buffer: float) -> float:
    start_time = time.perf_counter()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(node.ip, node.port, ssl=_SSL_CTX, server_hostname=SPEED_DOMAIN),
            timeout=timeout
        )
        req = f"GET {SPEED_PATH}?bytes={SPEED_BYTES} HTTP/1.1\r\nHost: {SPEED_DOMAIN}\r\nUser-Agent: CFIPTools/2.0\r\nConnection: close\r\n\r\n"
        writer.write(req.encode())
        await writer.drain()
        
        header_data = b""
        while b"\r\n\r\n" not in header_data:
            chunk = await asyncio.wait_for(reader.read(4096), timeout=timeout)
            if not chunk: break
            header_data += chunk
            if len(header_data) > 8192: break
            
        if b"200 OK" not in header_data:
            writer.close()
            await writer.wait_closed()
            return 0.0
            
        bytes_received = len(header_data)
        while True:
            chunk = await asyncio.wait_for(reader.read(65536), timeout=timeout)
            if not chunk: break
            bytes_received += len(chunk)
            if time.perf_counter() - start_time > timeout:
                break
                
        writer.close()
        await writer.wait_closed()
        
        total_time = time.perf_counter() - start_time
        if total_time <= 0 or bytes_received == 0: return 0.0
        return round((bytes_received * 8) / (total_time * 1_000_000), 2)
    except Exception:
        return 0.0

async def run_speed_tests(candidates: Sequence[TcpResult], *, timeout: float, process_buffer: float, workers: int, min_speed: float, test_count: int, verbose: bool) -> list[SpeedResult]:
    total_speeds = defaultdict(float)
    
    for i in range(test_count):
        iteration_str = f"{i+1}/{test_count}"
        status_msg = f"第{iteration_str}次 下载测速"
        set_status(status_msg)
        print(f"--- [INFO] 开始 {status_msg} ---")
        
        queue = asyncio.Queue()
        total = len(candidates)
        task_name = f"下载测速({iteration_str})"
        completed = 0

        async def worker():
            nonlocal completed
            while True:
                candidate = await queue.get()
                if candidate is None:
                    queue.task_done()
                    return
                try:
                    speed = await measure_speed_async(candidate.node, timeout, process_buffer)
                    total_speeds[candidate.node] += speed
                    if verbose: print(f"\n[SPEED] {candidate.node.raw} -> {speed} Mbps")
                except Exception as e:
                    if verbose: print(f"\n[SPEED Error] {candidate.node.raw} -> {e}")
                finally:
                    async with print_lock:
                        completed += 1
                        print_progress(task_name, completed, total)
                    queue.task_done()

        tasks = [asyncio.create_task(worker()) for _ in range(positive_worker_count(workers, len(candidates)))]
        for cand in candidates: queue.put_nowait(cand)
        for _ in tasks: queue.put_nowait(None)
        await queue.join()
        await asyncio.gather(*tasks)
        print()
        
    results = []
    for cand in candidates:
        avg_spd = round(total_speeds[cand.node] / test_count, 2) if test_count > 0 else 0.0
        results.append(SpeedResult(node=cand.node, latency_ms=cand.latency_ms, speed_mbps=avg_spd, is_fast=avg_spd > min_speed))
        
    results.sort(key=lambda item: (item.latency_ms, -item.speed_mbps))
    return results

def build_label(result: SpeedResult, *, show_latency: bool, show_mbps: bool, fast_label: str) -> str:
    parts, fast_prefix = [], fast_label if result.is_fast else ""
    if show_latency: parts.append(f"{max(0, int(round(result.latency_ms)))}ms")
    if show_mbps: parts.append(f"{result.speed_mbps:.0f}M")
    inner = " | ".join(parts) if parts else ""
    if fast_prefix and inner: return f"[{fast_prefix}{inner}]"
    if fast_prefix: return f"[{fast_prefix.rstrip()}]"
    if inner: return f"[{inner}]"
    return ""

def write_results(path: Path, results: Iterable[SpeedResult], numbered_regions: bool, *, show_latency: bool = True, show_mbps: bool = False, fast_label: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as file:
        region_counts = defaultdict(int)
        for result in results:
            emoji = REGION_EMOJIS.get(result.node.region.upper(), "🌐")
            region_counts[result.node.region] += 1
            region_name = f"{result.node.region}_{region_counts[result.node.region]}" if numbered_regions else result.node.region
            label = build_label(result, show_latency=show_latency, show_mbps=show_mbps, fast_label=fast_label)
            suffix = f" {label}" if label else ""
            file.write(f"{result.node.ip}:{result.node.port}#{emoji} {region_name}{suffix}\n")

def filter_fast_results(results: Iterable[SpeedResult]) -> list[SpeedResult]: return [r for r in results if r.is_fast]

async def run(config: AppConfig) -> int:
    if config.full_output_file.resolve() == config.best_output_file.resolve():
        print("ERROR: --output and --best-output must point to different files"); return 1
        
    try: nodes = load_nodes(config.input_file)
    except FileNotFoundError as exc: print(f"ERROR: {exc}"); return 1
    if not nodes: print(f"ERROR: no valid nodes found in {config.input_file}"); return 1

    # 1. 第一轮扫描全部 IP：快速 TCP 握手初筛
    tcp_results = await run_latency_tests(nodes, timeout=config.tcp_timeout, workers=config.tcp_workers, verbose=config.verbose)
    
    # 2. 选拔尖子生：每区前 N 名，并丢弃一次性高延迟节点
    candidates = select_candidates(tcp_results, config.top_per_region, config.max_latency_ms)

    # 3. 军事化过滤：对入围节点进行严格 TCP 多次复测淘汰赛
    if config.strict_tcp_count > 0:
        candidates = await verify_candidates_strict(candidates, config.strict_tcp_count, config.tcp_timeout, config.tcp_workers, config.max_latency_ms, config.verbose)

    # 4. 终极考验：只有幸存的极稳节点才进行大带宽下载测速
    speed_results = await run_speed_tests(candidates, timeout=config.speed_timeout, process_buffer=config.speed_process_buffer, workers=config.speed_workers, min_speed=config.min_speed_mbps, test_count=config.speed_test_count, verbose=config.verbose) if candidates else []

    write_results(config.full_output_file, speed_results, config.numbered_regions, show_latency=config.show_latency, show_mbps=config.show_mbps, fast_label=config.fast_label)
    write_results(config.best_output_file, filter_fast_results(speed_results), config.numbered_regions, show_latency=config.show_latency, show_mbps=config.show_mbps, fast_label=config.fast_label)
    return 0

def main() -> int: return asyncio.run(run(parse_args()))
if __name__ == "__main__": raise SystemExit(main())