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

repo = os.environ.get("GITHUB_REPO")
branch = os.environ.get("GITHUB_BRANCH", "main")
token = os.environ.get("GITHUB_TOKEN")
message = os.environ.get("GITHUB_MESSAGE", "Update IP results")
proxy = os.environ.get("GIT_HTTPS_PROXY") or os.environ.get("GIT_HTTP_PROXY")

files = ["best_ips.txt", "full_ips.txt", "README.MD"]

if not token or not repo:
    sys.exit("Error: Missing token or repo")

# 修复安全隐患：开启正规默认的 HTTPS 安全上下文，防患间谍窃取 Token
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
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "CF-IP-Tools-Python"
    }
    
    # 核心防护：遇到 GitHub 限流(429)进行自动智能休眠
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
    for file in files:
        if os.path.exists(file):
            with open(file, "rb") as f:
                content = f.read()
            blob_data = api_req("POST", "/git/blobs", {
                "content": base64.b64encode(content).decode("utf-8"),
                "encoding": "base64"
            })
            tree_items.append({
                "path": file,
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
        print(f"Nothing to push: {files} are already up to date.")
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