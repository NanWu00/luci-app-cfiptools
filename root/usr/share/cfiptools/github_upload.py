#!/usr/bin/env python3
"""
GitHub upload script for CF IP Tools.
Reads environment variables (set by run.sh) and uploads result files.
"""
import sys
import os
import base64
import json
import urllib.request
import urllib.error
import ssl
import time

def main():
    repo = os.environ.get("GITHUB_REPO", "").strip()
    branch = os.environ.get("GITHUB_BRANCH", "main").strip()
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    message = os.environ.get("GITHUB_MESSAGE", "Update IP results").strip()
    proxy = os.environ.get("GIT_HTTPS_PROXY") or os.environ.get("GIT_HTTP_PROXY")

    if not token or not repo:
        print("ERROR: Missing GITHUB_REPO or GITHUB_TOKEN", file=sys.stderr)
        sys.exit(1)

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
            "Authorization": f"Bearer {token}",
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
                err_body = e.read().decode("utf-8")
                if e.code == 429:
                    print(f"Rate limited by GitHub (429) on attempt {attempt+1}. Waiting 10s...")
                    time.sleep(10)
                    continue
                print(f"GitHub API Error {e.code}: {err_body}", file=sys.stderr)
                sys.exit(1)
            except Exception as e:
                print(f"Network Error (attempt {attempt+1}/3): {e}", file=sys.stderr)
                if attempt < 2:
                    time.sleep(3)
                else:
                    print(f"Network Error after 3 attempts", file=sys.stderr)
                    sys.exit(1)

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
            print("No valid result files found to upload.", file=sys.stderr)
            sys.exit(1)

        new_tree_data = api_req("POST", "/git/trees", {
            "base_tree": base_tree_sha,
            "tree": tree_items
        })
        new_tree_sha = new_tree_data["sha"]

        if new_tree_sha == base_tree_sha:
            print("Nothing to push: local files are already up to date.")
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
        print(f"Upload failed: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()