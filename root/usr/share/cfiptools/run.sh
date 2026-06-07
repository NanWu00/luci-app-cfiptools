#!/bin/sh
# cfip-tools OpenWRT wrapper script - fixed version
set -e

CFG="/etc/config/cfiptools"
DATA_DIR="/usr/share/cfiptools"
STATUS_FILE="/var/run/cfiptools.status"
LOG_FILE="/var/log/cfiptools.log"
PID_FILE="/var/run/cfiptools.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
set_status() { echo "$1" > "$STATUS_FILE"; log "STATUS: $1"; }

load_uci() {
    local section="config"
    # 如果 config 节不存在，尝试获取第一个匿名节
    if ! uci -q get cfiptools.config >/dev/null 2>&1; then
        section=$(uci -q show cfiptools | head -n1 | cut -d. -f2 | cut -d= -f1)
        [ -z "$section" ] && section="config"
    fi

    uci_get() {
        local key="$1" default="$2"
        local v=$(uci -q get "cfiptools.${section}.${key}" 2>/dev/null)
        printf '%s' "${v:-$default}"
    }

    CFG_enabled=$(uci_get enabled "0")
    CFG_cron_schedule=$(uci_get cron_schedule "0 4 * * *")
    CFG_download_input=$(uci_get download_input "1")
    CFG_input_url=$(uci_get input_url "https://zip.cm.edu.kg/all.txt")
    CFG_download_timeout=$(uci_get download_timeout "30")
    CFG_input_file=$(uci_get input_file "$DATA_DIR/ips.txt")
    CFG_full_output_file=$(uci_get full_output_file "$DATA_DIR/full_ips.txt")
    CFG_best_output_file=$(uci_get best_output_file "$DATA_DIR/best_ips.txt")
    CFG_tcp_timeout_ms=$(uci_get tcp_timeout_ms "1500")
    CFG_tcp_workers=$(uci_get tcp_workers "200")
    CFG_speed_timeout_sec=$(uci_get speed_timeout_sec "6")
    CFG_speed_workers=$(uci_get speed_workers "5")
    CFG_min_speed_mbps=$(uci_get min_speed_mbps "16")
    CFG_top_per_region=$(uci_get top_per_region "10")
    CFG_max_nodes=$(uci_get max_nodes "0")
    CFG_show_latency=$(uci_get show_latency "1")
    CFG_show_bandwidth=$(uci_get show_bandwidth "1")
    CFG_numbered_regions=$(uci_get numbered_regions "0")
    CFG_verbose=$(uci_get verbose "0")
    CFG_fast_label=$(uci_get fast_label "优选高速")
    CFG_update_readme=$(uci_get update_readme "0")
    CFG_readme_file=$(uci_get readme_file "$DATA_DIR/README.MD")
    CFG_github_upload_enabled=$(uci_get github_upload_enabled "0")
    CFG_github_repo=$(uci_get github_repo "")
    CFG_github_branch=$(uci_get github_branch "main")
    CFG_github_token=$(uci_get github_token "")
    CFG_github_message=$(uci_get github_message "Update IP and README")
    CFG_git_http_proxy=$(uci_get git_http_proxy "")
    CFG_git_https_proxy=$(uci_get git_https_proxy "")
    CFG_bypass_proxy_method=$(uci_get bypass_proxy_method "env")
    CFG_pre_test_command=$(uci_get pre_test_command "")
    CFG_post_test_command=$(uci_get post_test_command "")
}

apply_proxy_bypass() {
    local method="${CFG_bypass_proxy_method:-env}"
    export http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY="" no_proxy="*" NO_PROXY="*"
    case "$method" in
        iptables)
            if command -v iptables >/dev/null 2>&1; then
                iptables -t nat -I OUTPUT 1 -m owner --uid-owner root -j RETURN -m comment --comment "cfiptools_bypass" 2>/dev/null || true
                iptables -t mangle -I OUTPUT 1 -m owner --uid-owner root -j RETURN -m comment --comment "cfiptools_bypass" 2>/dev/null || true
                log "Added iptables bypass rule"
            else
                log "iptables not found, skip"
            fi ;;
        nftables)
            if command -v nft >/dev/null 2>&1; then
                nft list ruleset 2>/dev/null | awk '
                    /table (inet|ip|ip6) / { fam=$2; tbl=$3; gsub(/\"/, "", tbl) }
                    /chain/ { chn=$2; gsub(/\"/, "", chn) }
                    /hook output/ { print fam, tbl, chn }
                ' | while read -r fam tbl chn; do
                    nft insert rule "$fam" "$tbl" "$chn" meta skuid root counter return comment \"cfiptools_bypass\" 2>/dev/null || true
                done
                log "Added dynamic nftables bypass rules"
            else
                log "nftables not found, skip"
            fi ;;
    esac
}

cleanup_proxy_bypass() {
    local method="${CFG_bypass_proxy_method:-env}"
    case "$method" in
        iptables)
            while iptables -t nat -D OUTPUT -m owner --uid-owner root -j RETURN -m comment --comment "cfiptools_bypass" 2>/dev/null; do :; done
            while iptables -t mangle -D OUTPUT -m owner --uid-owner root -j RETURN -m comment --comment "cfiptools_bypass" 2>/dev/null; do :; done
            log "Removed iptables bypass rule" ;;
        nftables)
            if command -v nft >/dev/null 2>&1; then
                nft -a list ruleset 2>/dev/null | awk '
                    /table (inet|ip|ip6) / { fam=$2; tbl=$3; gsub(/\"/, "", tbl) }
                    /chain/ { chn=$2; gsub(/\"/, "", chn) }
                    /cfiptools_bypass/ { print fam, tbl, chn, $NF }
                ' | while read -r fam tbl chn hnd; do
                    nft delete rule "$fam" "$tbl" "$chn" handle "$hnd" 2>/dev/null || true
                done
                log "Removed dynamic nftables bypass rules"
            fi ;;
    esac
}

run_pre_command() {
    if [ -n "${CFG_pre_test_command:-}" ]; then
        log "Running pre-test: ${CFG_pre_test_command}"
        eval "$CFG_pre_test_command" >> "$LOG_FILE" 2>&1 || log "Pre-test failed (ignored)"
    fi
}

run_post_command() {
    if [ -n "${CFG_post_test_command:-}" ]; then
        log "Running post-test: ${CFG_post_test_command}"
        eval "$CFG_post_test_command" >> "$LOG_FILE" 2>&1 || log "Post-test failed (ignored)"
    fi
}

run_python() {
    cd "$DATA_DIR"
    # -u 强制取消 Python 的全缓冲，实时写入日志
    python3 -u "$DATA_DIR/update.py" "$@" >> "$LOG_FILE" 2>&1
}

run_test() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "Already running (PID $(cat "$PID_FILE"))"
        set_status "已在运行"
        exit 1
    fi
    echo $$ > "$PID_FILE"

    trap 'cleanup_proxy_bypass; pkill -9 -f "update.py" 2>/dev/null; pkill -9 -f "curl.*speed.cloudflare.com" 2>/dev/null; rm -f "$PID_FILE"' EXIT INT TERM

    load_uci
    run_pre_command
    apply_proxy_bypass

    INPUT_FILE="${CFG_input_file}"
    FULL_OUTPUT="${CFG_full_output_file}"
    BEST_OUTPUT="${CFG_best_output_file}"
    README_FILE="${CFG_readme_file}"

    log "Paths: input=$INPUT_FILE | full=$FULL_OUTPUT | best=$BEST_OUTPUT | readme=$README_FILE"

    if [ "${CFG_download_input:-1}" = "1" ] && [ -n "${CFG_input_url:-}" ]; then
        set_status "下载IP列表"
        log "Downloading IP list from ${CFG_input_url}"
        DOWNLOAD_TO="${CFG_download_timeout:-30}"
        mkdir -p "$(dirname "$INPUT_FILE")"
        if curl -sL --connect-timeout "$DOWNLOAD_TO" --max-time "$((DOWNLOAD_TO * 2))" \
            -H "User-Agent: cf-ip-updater/1.0" \
            -o "$INPUT_FILE" "${CFG_input_url}" >> "$LOG_FILE" 2>&1; then
            log "Download succeeded"
        else
            log "Download failed, will try to use existing file"
        fi
    fi

    if [ ! -f "$INPUT_FILE" ]; then
        set_status "失败：无输入文件"
        log "ERROR: Input file $INPUT_FILE not found and download failed"
        exit 1
    fi

    MAX_NODES="${CFG_max_nodes:-0}"
    if [ "$MAX_NODES" -gt 0 ] 2>/dev/null; then
        log "Limiting to first $MAX_NODES nodes"
        TMP_INPUT="${INPUT_FILE}.limited"
        head -n "$MAX_NODES" "$INPUT_FILE" > "$TMP_INPUT"
        INPUT_FILE="$TMP_INPUT"
    fi

    TCP_TIMEOUT_MS="${CFG_tcp_timeout_ms:-1500}"
    TCP_TIMEOUT_SEC=$(awk "BEGIN {printf \"%.3f\", $TCP_TIMEOUT_MS / 1000}")

    set --
    set -- "--input" "$INPUT_FILE"
    set -- "$@" "--output" "$FULL_OUTPUT"
    set -- "$@" "--best-output" "$BEST_OUTPUT"
    set -- "$@" "--tcp-timeout" "$TCP_TIMEOUT_SEC"
    set -- "$@" "--tcp-workers" "${CFG_tcp_workers:-200}"
    set -- "$@" "--speed-timeout" "${CFG_speed_timeout_sec:-6.0}"
    set -- "$@" "--speed-workers" "${CFG_speed_workers:-5}"
    set -- "$@" "--min-speed" "${CFG_min_speed_mbps:-16}"
    set -- "$@" "--top" "${CFG_top_per_region:-10}"
    set -- "$@" "--show-latency" "${CFG_show_latency:-1}"
    set -- "$@" "--show-mbps" "${CFG_show_bandwidth:-1}"

    if [ "${CFG_numbered_regions:-0}" = "1" ]; then set -- "$@" "--numbered"; fi
    if [ "${CFG_verbose:-0}" = "1" ]; then set -- "$@" "--verbose"; fi
    set -- "$@" "--fast-label" "${CFG_fast_label:-优选高速}"

    set_status "TCP延迟测速"
    log "Starting speed test..."
    if run_python "$@"; then
        log "update.py finished successfully"
    else
        local exit_code=$?
        set_status "失败"
        log "update.py failed with exit code $exit_code"
        run_post_command
        exit $exit_code
    fi

    if [ "${CFG_update_readme:-0}" = "1" ]; then
        set_status "生成README"
        log "Generating README -> $README_FILE"
        if [ -f "$DATA_DIR/update_md.py" ]; then
            python3 "$DATA_DIR/update_md.py" -f "$README_FILE" >> "$LOG_FILE" 2>&1 || log "README generation failed (ignored)"
        else
            log "update_md.py not found, skip README generation"
        fi
    fi

    if [ "${CFG_github_upload_enabled:-0}" = "1" ]; then
        set_status "上传GitHub"
        log "Starting GitHub upload..."
        export ENABLE_GITHUB_UPLOAD="true"
        export GITHUB_REPO="${CFG_github_repo:-}"
        export GITHUB_BRANCH="${CFG_github_branch:-main}"
        export GITHUB_TOKEN="${CFG_github_token:-}"
        export GITHUB_MESSAGE="${CFG_github_message:-Update IP and README}"
        export GIT_HTTP_PROXY="${CFG_git_http_proxy:-}"
        export GIT_HTTPS_PROXY="${CFG_git_https_proxy:-}"

        if [ -f "$DATA_DIR/push_results.sh" ]; then
            sh "$DATA_DIR/push_results.sh" >> "$LOG_FILE" 2>&1
            local push_exit=$?
            if [ $push_exit -eq 0 ]; then log "GitHub upload completed"; else log "GitHub upload failed (exit $push_exit)"; fi
        else
            log "push_results.sh not found, skip GitHub upload"
        fi
    fi

    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    uci -q set cfiptools.config.last_run="$ts"
    uci -q set cfiptools.config.last_result="success"
    uci -q commit cfiptools
    set_status "完成"
    log "All tasks completed"

    run_post_command
    # 清理操作将由 trap 自动接管
}

run_test