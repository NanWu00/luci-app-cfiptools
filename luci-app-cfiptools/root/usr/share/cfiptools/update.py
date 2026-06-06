import argparse
import asyncio
import heapq
import os
import shutil
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence
from tqdm import tqdm

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
DEFAULT_TOP_PER_REGION = 10

SPEED_DOMAIN = "speed.cloudflare.com"
SPEED_PATH = "/__down"
SPEED_BYTES = 2 * 1024 * 1024
DEFAULT_FAST_LABEL = "自选高速"
MY_REGION = "KG2"
MY_SUPPLEMENT_TRIGGER_COUNT = 2
MY_SUPPLEMENT_LIMIT = 2

IS_TTY = sys.stdout.isatty()

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

def parse_bool(value: str) -> bool:
    text = value.strip().lower()
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
    parser.add_argument("--top", type=int, default=DEFAULT_TOP_PER_REGION)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--NO", nargs="?", const="true", default=os.environ.get("NO", "false"))
    parser.add_argument("--show-latency", nargs="?", const="true", default=os.environ.get("SHOW_LATENCY", "true"))
    parser.add_argument("--show-mbps", nargs="?", const="true", default=os.environ.get("SHOW_MBPS", "false"))
    parser.add_argument("--fast-label", type=str, default=DEFAULT_FAST_LABEL)
    parser.add_argument("--input-url", type=str, default=DEFAULT_INPUT_URL)
    args = parser.parse_args()

    return AppConfig(
        input_file=args.input, full_output_file=args.output, best_output_file=args.best_output,
        tcp_timeout=args.tcp_timeout, tcp_workers=args.tcp_workers, speed_timeout=args.speed_timeout,
        speed_process_buffer=args.speed_process_buffer, speed_workers=args.speed_workers,
        min_speed_mbps=args.min_speed, top_per_region=args.top, verbose=args.verbose,
        numbered_regions=parse_bool(args.NO), show_latency=parse_bool(args.show_latency),
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

def refresh_input_file(url: str, path: Path, timeout: float) -> bool:
    temp_path = path.with_name(f"{path.name}.download")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers={"User-Agent": "cf-ip-updater/1.0"})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200: raise RuntimeError(f"HTTP {response.status}")
            with temp_path.open("wb") as file: shutil.copyfileobj(response, file)
        if temp_path.stat().st_size == 0: raise RuntimeError("downloaded file is empty")
        temp_path.replace(path)
        print(f"Downloaded input file from {url} to {path}")
        return True
    except Exception as exc:
        if temp_path.exists():
            try: temp_path.unlink()
            except OSError: pass
        print(f"Input download failed: {exc}; using local {path}")
        return False

def positive_worker_count(req: int, total: int) -> int: return max(1, min(max(1, req), max(1, total)))

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

async def run_tcp_tests(nodes: Sequence[Node], *, timeout: float, workers: int, verbose: bool) -> list[TcpResult]:
    queue, results = asyncio.Queue(), []
    progress = tqdm(total=len(nodes), desc="TCP latency", unit="ip", disable=not IS_TTY)

    async def worker():
        while True:
            node = await queue.get()
            try:
                if node is None: return
                latency = await tcping(node, timeout)
                if latency is not None:
                    results.append(TcpResult(node=node, latency_ms=latency))
                    if verbose:
                        (tqdm.write if IS_TTY else print)(f"[LAT] {node.raw} -> {latency} ms")
                progress.update(1)
            finally: queue.task_done()

    tasks = [asyncio.create_task(worker()) for _ in range(positive_worker_count(workers, len(nodes)))]
    for node in nodes: queue.put_nowait(node)
    for _ in tasks: queue.put_nowait(None)
    await queue.join()
    await asyncio.gather(*tasks)
    progress.close()
    return results

def select_candidates(results: Iterable[TcpResult], top_per_region: int) -> list[TcpResult]:
    groups = defaultdict(list)
    limit = max(1, top_per_region)
    for index, result in enumerate(results):
        heap = groups[result.node.region]
        item = (-result.latency_ms, -index, result)
        if len(heap) < limit: heapq.heappush(heap, item)
        else: heapq.heappushpop(heap, item)
    candidates = [item[2] for region in sorted(groups) for item in groups[region]]
    candidates.sort(key=lambda item: (item.node.region, item.latency_ms))
    return candidates

def get_curl_command() -> str | None:
    return shutil.which("curl.exe") if sys.platform == "win32" else shutil.which("curl")

def parse_curl_speed(stdout: str) -> float:
    try:
        size_text, time_text, *_ = stdout.strip().split()
        size_bytes, time_total = float(size_text), float(time_text)
    except ValueError: return 0.0
    if size_bytes <= 0 or time_total <= 0: return 0.0
    return round((size_bytes * 8) / (time_total * 1_000_000), 2)

async def measure_speed_async(node: Node, timeout: float, process_buffer: float) -> float:
    curl = get_curl_command()
    if curl is None: return 0.0
    url = f"https://{SPEED_DOMAIN}:{node.port}{SPEED_PATH}?bytes={SPEED_BYTES}"
    cmd = [
        curl, "-s", "-o", "NUL" if sys.platform == "win32" else "/dev/null",
        "-w", "%{size_download} %{time_total}", "--resolve", f"{SPEED_DOMAIN}:{node.port}:{node.ip}",
        "--connect-timeout", str(min(5.0, timeout)), "--max-time", str(timeout), "--insecure", url,
    ]
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        stdout_bytes, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout + process_buffer)
        if proc.returncode != 0: return 0.0
        return parse_curl_speed(stdout_bytes.decode('utf-8'))
    except Exception:
        if proc:
            try: proc.kill()
            except OSError: pass
        return 0.0

async def run_speed_tests(candidates: Sequence[TcpResult], *, timeout: float, process_buffer: float, workers: int, min_speed: float, verbose: bool) -> list[SpeedResult]:
    queue, results = asyncio.Queue(), []
    progress = tqdm(total=len(candidates), desc="Download speed", unit="ip", disable=not IS_TTY)

    async def worker():
        while True:
            candidate = await queue.get()
            try:
                if candidate is None: return
                speed = await measure_speed_async(candidate.node, timeout, process_buffer)
                result = SpeedResult(node=candidate.node, latency_ms=candidate.latency_ms, speed_mbps=speed, is_fast=speed > min_speed)
                results.append(result)
                if verbose:
                    status = "FAST" if result.is_fast else "NORMAL"
                    (tqdm.write if IS_TTY else print)(f"[SPEED] {candidate.node.raw} -> {speed} Mbps {status}")
                progress.update(1)
            finally: queue.task_done()

    tasks = [asyncio.create_task(worker()) for _ in range(positive_worker_count(workers, len(candidates)))]
    for candidate in candidates: queue.put_nowait(candidate)
    for _ in tasks: queue.put_nowait(None)
    await queue.join()
    await asyncio.gather(*tasks)
    progress.close()
    results.sort(key=lambda item: (item.node.region, item.latency_ms, -item.speed_mbps))
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
def is_region(node: Node, region: str) -> bool: return node.region.upper() == region.upper()
def node_key(node: Node) -> tuple[str, int, str]: return (node.ip, node.port, node.region.upper())

async def supplement_my_results(best_results: Sequence[SpeedResult], tcp_results: Sequence[TcpResult], config: AppConfig) -> list[SpeedResult]:
    results = list(best_results)
    my_count = sum(1 for result in results if is_region(result.node, MY_REGION))
    if my_count > MY_SUPPLEMENT_TRIGGER_COUNT: return results
    my_candidates = [result for result in tcp_results if is_region(result.node, MY_REGION)]
    if not my_candidates: return results
    tested_my_results = await run_speed_tests(my_candidates, timeout=config.speed_timeout, process_buffer=config.speed_process_buffer, workers=config.speed_workers, min_speed=config.min_speed_mbps, verbose=config.verbose)
    existing_nodes = {node_key(result.node) for result in results}
    additions = [result for result in tested_my_results if node_key(result.node) not in existing_nodes and result.speed_mbps > 0]
    additions.sort(key=lambda item: (-item.speed_mbps, item.latency_ms, item.node.ip, item.node.port))
    selected = additions[:MY_SUPPLEMENT_LIMIT]
    if selected:
        results.extend(selected)
        results.sort(key=lambda item: (item.node.region, item.latency_ms, -item.speed_mbps))
    return results

async def run(config: AppConfig) -> int:
    if config.full_output_file.resolve() == config.best_output_file.resolve():
        print("ERROR: --output and --best-output must point to different files"); return 1
    refresh_input_file(config.input_url, config.input_file, DEFAULT_INPUT_DOWNLOAD_TIMEOUT)
    try: nodes = load_nodes(config.input_file)
    except FileNotFoundError as exc: print(f"ERROR: {exc}"); return 1
    if not nodes: print(f"ERROR: no valid nodes found in {config.input_file}"); return 1
    
    tcp_results = await run_tcp_tests(nodes, timeout=config.tcp_timeout, workers=config.tcp_workers, verbose=config.verbose)
    candidates = select_candidates(tcp_results, config.top_per_region)
    
    speed_results = await run_speed_tests(candidates, timeout=config.speed_timeout, process_buffer=config.speed_process_buffer, workers=config.speed_workers, min_speed=config.min_speed_mbps, verbose=config.verbose) if candidates else []
    
    best_results = await supplement_my_results(filter_fast_results(speed_results), tcp_results, config)
    write_results(config.full_output_file, speed_results, config.numbered_regions, show_latency=config.show_latency, show_mbps=config.show_mbps, fast_label=config.fast_label)
    write_results(config.best_output_file, best_results, config.numbered_regions, show_latency=config.show_latency, show_mbps=config.show_mbps, fast_label=config.fast_label)
    return 0

def main() -> int: return asyncio.run(run(parse_args()))
if __name__ == "__main__": raise SystemExit(main())