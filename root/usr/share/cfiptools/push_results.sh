#!/bin/sh
set -u

ENABLE_GITHUB_UPLOAD="${ENABLE_GITHUB_UPLOAD:-true}"
export GITHUB_REPO="${GITHUB_REPO:-}"
export GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GITHUB_MESSAGE="${GITHUB_MESSAGE:-Update IP results and README}"
export GIT_HTTP_PROXY="${GIT_HTTP_PROXY:-}"
export GIT_HTTPS_PROXY="${GIT_HTTPS_PROXY:-$GIT_HTTP_PROXY}"

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT" || exit 1

die() {
    echo "$*" >&2
    exit 1
}

is_enabled() {
    local val
    val=$(echo "$1" | tr 'A-Z' 'a-z')
    case "$val" in
        1|true|yes|on) return 0 ;;
        0|false|no|off|"") return 1 ;;
        *) die "invalid boolean value: $1" ;;
    esac
}

upload_github() {
    if [ -z "$GITHUB_REPO" ]; then
        die 'GITHUB_REPO is not set.'
    fi
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "Warning: GITHUB_TOKEN is not set." >&2
    else
        echo "GitHub token loaded from environment."
    fi

    echo "Uploading via GitHub REST API (Python)..."

    python3 -c '
import sys, os, base64, json, urllib.request, urllib.error, ssl, time

# 核心防呆：使用 strip() 强制剥离任何可能被用户不小心复制进去的空格和换行符
repo = os.environ.get("GITHUB_REPO", "").strip()
branch = os.environ.get("GITHUB_BRANCH", "main").strip()
token = os.environ.get("GITHUB_TOKEN", "").strip()
message = os.environ.get("GITHUB_MESSAGE", "Update IP results").strip()
proxy = os.environ.get("GIT_HTTPS_PROXY") or os.environ.get("GIT_HTTP_PROXY")

if not token or not repo:
    sys.exit("Error: Missing token or repo")

best_file = os.environ.get("GITHUB_FILE_BEST", "best_ips.txt").strip()
full_file = os.environ.get("GITHUB_FILE_FULL", "full_ips.txt").strip()
readme_file = os.environ.get("GITHUB_FILE_README", "README.MD").strip()
files_to_check = [best_file, full_file, readme_file]

ctx = ssl.create_default_context()

if proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    opener = urllib.request.build_opener(proxy_handler, urllib.request.HTTPSHandler(context=ctx))
else:
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
urllib.request.install_opener(opener)

def api_req(method, endpoint, data=None):
    url = f"https://api.github.com/repos/{repo}{endpoint}"
    headers = {
        "Authorization": f"Bearer {token}",  # 升级为最新的 Bearer 鉴权标准
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "CF-IP-Tools-Python"
    }
    
    for attempt in range(3):
        req = urllib.request.Request(url, method=method, headers=headers)
        if data is not None:
            req.data = json.dumps(data).encode("utf-8")
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=20) as f:
                return json.loads(f.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            err = e.read().decode("utf-8")
            if e.code == 429:
                print(f"Rate limited by GitHub (429) on attempt {attempt+1}. Waiting 10s...")
                time.sleep(10)
                continue
            sys.exit(f"GitHub API Error {e.code}: {err}")
        except Exception as e:
            print(f"Network Error (attempt {attempt+1}/3): {e}")
            if attempt < 2:
                time.sleep(3)
            else:
                sys.exit(f"Network Error after 3 attempts: {e}")

try:
    ref_data = api_req("GET", f"/git/refs/heads/{branch}")
    commit_sha = ref_data["object"]["sha"]
    commit_data = api_req("GET", f"/git/commits/{commit_sha}")
    base_tree_sha = commit_data["tree"]["sha"]

    tree_items = []
    for file_path in files_to_check:
        if os.path.exists(file_path):
            with open(file_path, "rb") as f:
                content = f.read()
            blob_data = api_req("POST", "/git/blobs", {
                "content": base64.b64encode(content).decode("utf-8"),
                "encoding": "base64"
            })
            tree_items.append({
                "path": os.path.basename(file_path),
                "mode": "100644",
                "type": "blob",
                "sha": blob_data["sha"]
            })

    if not tree_items:
        sys.exit("No valid result files found to upload.")

    new_tree_data = api_req("POST", "/git/trees", {
        "base_tree": base_tree_sha,
        "tree": tree_items
    })
    new_tree_sha = new_tree_data["sha"]

    if new_tree_sha == base_tree_sha:
        print(f"Nothing to push: local files are already up to date.")
        sys.exit(0)

    new_commit_data = api_req("POST", "/git/commits", {
        "message": message,
        "tree": new_tree_sha,
        "parents": [commit_sha]
    })
    new_commit_sha = new_commit_data["sha"]

    api_req("PATCH", f"/git/refs/heads/{branch}", {
        "sha": new_commit_sha
    })
    print(f"Push done. Commit {new_commit_sha[:7]} created successfully.")
except Exception as e:
    sys.exit(f"Upload failed: {e}")
'
}

if is_enabled "$ENABLE_GITHUB_UPLOAD"; then
    if upload_github; then
        echo "GitHub upload finished."
    else
        echo "GitHub upload failed." >&2
        exit 1
    fi
else
    echo "GitHub upload disabled."
fi

exit 0