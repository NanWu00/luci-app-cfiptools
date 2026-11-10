#!/bin/sh
# cfip-tools OpenWRT wrapper script - V2 Architecture (Bugfix Edition)
set -e

CFG="/etc/config/cfiptools"
DATA_DIR="/usr/share/cfiptools"
STATUS_FILE="/var/run/cfiptools.status"
LOG_FILE="/var/log/cfiptools.log"
PID_FILE="/var/run/cfiptools.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
set_status() { echo "$1" > "$STATUS_FILE"; log "STATUS: $1"; }

load_uci() {
    local section="config"
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
    CFG_max_latency_ms=$(uci_get max_latency_ms "0")
    CFG_strict_tcp_count=$(uci_get strict_tcp_count "0")
    CFG_speed_test_count=$(uci_get speed_test_count "1")
    CFG_top_per_region=$(uci_get top_per_region "5")
    CFG_best_top=$(uci_get best_top "3")
    CFG_tls_probe=$(uci_get tls_probe "1")
    CFG_tls_timeout_sec=$(uci_get tls_timeout_sec "3")
    CFG_tls_workers=$(uci_get tls_workers "8")
    CFG_speed_sni=$(uci_get speed_sni "")
    CFG_speed_domain=$(uci_get speed_domain "speed.cloudflare.com")
    CFG_speed_window_sec=$(uci_get speed_window_sec "2")
    CFG_port_whitelist=$(uci_get port_whitelist "")
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
    CFG_blocked_regions=$(uci_get blocked_regions "")
    CFG_git_http_proxy=$(uci_get git_http_proxy "")
    CFG_git_https_proxy=$(uci_get git_https_proxy "")
    CFG_bypass_proxy_method=$(uci_get bypass_proxy_method "nftables")
    CFG_pre_test_command=$(uci_get pre_test_command "")
    CFG_post_test_command=$(uci_get post_test_command "")
}

# 旁路方案：给测速 socket 打 SO_MARK，只在每条 output 链首插一条"见 mark 即 return"的规则。
# 相比 skuid root，影响面从"整机 root 流量"缩小到"本脚本自己的连接"。
BYPASS_MARK="0xcf"
BYPASS_COMMENT="cfiptools_bypass"
BYPASS_HANDLE_FILE="/var/run/cfiptools.nft.handles"

# 找出所有挂在 output 钩子上的链（不写死 fw4：homeproxy 等可能自建 table）
list_output_chains() {
    nft list ruleset 2>/dev/null | awk '
        /^[[:space:]]*table (inet|ip|ip6) / { fam=$2; tbl=$3; gsub(/"/, "", tbl) }
        /^[[:space:]]*chain[[:space:]]/ { chn=$2; gsub(/"/, "", chn) }
        /hook output/ { print fam, tbl, chn }
    '
}

apply_proxy_bypass() {
    local method="${CFG_bypass_proxy_method:-nftables}"
    export http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY="" no_proxy="*" NO_PROXY="*"
    case "$method" in
        none|off|0)
            log "旁路已关闭（bypass_proxy_method=$method）：测速流量仍可能被透明代理劫持"
            return 0
            ;;
        nftables|"")
            ;;
        *)
            # 老配置里的 env / iptables 都拦不住透明代理（env 只影响自己读环境变量的程序，
            # iptables 在 fw4 下是另一张表），统一按 nftables 处理
            log "bypass_proxy_method='$method' 已不支持，按 nftables 处理"
            ;;
    esac
    if ! command -v nft >/dev/null 2>&1; then
        log "WARNING: 未找到 nft，跳过旁路规则（测速流量可能被透明代理劫持）"
        return 0
    fi

    cleanup_proxy_bypass   # 先清残留，避免上次异常退出留下的规则被重复插入

    : > "$BYPASS_HANDLE_FILE"
    list_output_chains | while read -r fam tbl chn; do
        # 注意：nft 的 comment 必须放在整条规则的**最后**，写在 verdict 前面会报
        # "syntax error, unexpected return"（nftables 1.1.6 实测）
        err=$(nft insert rule "$fam" "$tbl" "$chn" \
                meta mark "$BYPASS_MARK" counter return comment "\"$BYPASS_COMMENT\"" 2>&1)
        if [ $? -ne 0 ]; then
            log "WARN: 无法向 $fam/$tbl/$chn 插入旁路规则：$err"
            continue
        fi
        hnd=$(nft -a list chain "$fam" "$tbl" "$chn" 2>/dev/null | awk -v c="$BYPASS_COMMENT" '
            $0 ~ c { for (i=1; i<=NF; i++) if ($i=="handle") { print $(i+1); exit } }
        ')
        [ -n "$hnd" ] && printf '%s %s %s %s\n' "$fam" "$tbl" "$chn" "$hnd" >> "$BYPASS_HANDLE_FILE"
    done

    applied=0
    if [ -s "$BYPASS_HANDLE_FILE" ]; then applied=$(wc -l < "$BYPASS_HANDLE_FILE"); fi
    log "旁路规则已插入：mark=$BYPASS_MARK，覆盖 $applied 条 output 链"
    [ "$applied" -gt 0 ] || log "WARNING: 没有可用的 output 链，透明代理可能仍会劫持测速流量"
}

# 幂等清理：先按 handle 文件精确删除，再按注释兜底扫描（handle 文件可能因 kill -9 丢失）
cleanup_proxy_bypass() {
    command -v nft >/dev/null 2>&1 || return 0
    if [ -s "$BYPASS_HANDLE_FILE" ]; then
        while read -r fam tbl chn hnd; do
            nft delete rule "$fam" "$tbl" "$chn" handle "$hnd" 2>/dev/null || true
        done < "$BYPASS_HANDLE_FILE"
        rm -f "$BYPASS_HANDLE_FILE"
    fi
    nft -a list ruleset 2>/dev/null | awk -v c="$BYPASS_COMMENT" '
        /^[[:space:]]*table (inet|ip|ip6) / { fam=$2; tbl=$3; gsub(/"/, "", tbl) }
        /^[[:space:]]*chain[[:space:]]/ { chn=$2; gsub(/"/, "", chn) }
        $0 ~ c {
            for (i=1; i<=NF; i++) if ($i=="handle") { print fam, tbl, chn, $(i+1); break }
        }
    ' | while read -r fam tbl chn hnd; do
        nft delete rule "$fam" "$tbl" "$chn" handle "$hnd" 2>/dev/null || true
    done
    log "旁路规则已清理"
}

# 提供给 Lua 的安全清理通道
if [ "$1" = "cleanup" ]; then
    cleanup_proxy_bypass
    exit 0
fi

run_pre_command() {
    if [ -n "${CFG_pre_test_command:-}" ]; then
        log "Running pre-test: ${CFG_pre_test_command}"
        sh -c "$CFG_pre_test_command" >> "$LOG_FILE" 2>&1 || log "Pre-test failed (ignored)"
    fi
}

run_post_command() {
    if [ -n "${CFG_post_test_command:-}" ]; then
        log "Running post-test: ${CFG_post_test_command}"
        sh -c "$CFG_post_test_command" >> "$LOG_FILE" 2>&1 || log "Post-test failed (ignored)"
    fi
}

PY_PID=""

run_python() {
    cd "$DATA_DIR" || return 1
    # 后台起 + wait：这样中断信号到来时能精确杀掉自己这个子进程，而不是 pkill 全场
    if ! command -v python3 >/dev/null 2>&1; then
        log "ERROR: 找不到 python3，请先安装：apk add python3"
        set_status "失败"
        uci -q set cfiptools.config.last_result="no_python3"
        uci -q set cfiptools.config.last_run="$(date '+%Y-%m-%d %H:%M:%S')"
        return 127
    fi

    python3 -u "$DATA_DIR/update.py" "$@" >> "$LOG_FILE" 2>&1 &
    PY_PID=$!
    rc=0
    wait "$PY_PID" || rc=$?
    PY_PID=""
    return $rc
}

CLEANUP_DONE=0

# 幂等清理：正常退出、失败退出、被信号打断，都会走到这里
cleanup_all() {
    [ "$CLEANUP_DONE" = "1" ] && return 0
    CLEANUP_DONE=1
    cleanup_proxy_bypass
    rm -f "$PID_FILE"
}

cleanup_on_abort() {
    log "收到中断信号，开始清理"
    if [ -n "$PY_PID" ]; then
        kill -9 "$PY_PID" 2>/dev/null || true
    fi
    cleanup_all
}

run_test() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            if grep -q -E "run\.sh|cfiptools" "/proc/$pid/cmdline" 2>/dev/null; then
                log "Already running (PID $pid)"
                set_status "已在运行"
                exit 1
            fi
        fi
    fi
    echo $$ > "$PID_FILE"

    # 任何退出路径都保证撤销防火墙规则（原来只有正常路径手动清，崩溃/失败会残留）
    trap 'cleanup_on_abort; exit 130' INT
    trap 'cleanup_on_abort; exit 143' TERM
    trap 'cleanup_all; log "Normal exit"' EXIT

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
            -H "User-Agent: cf-ip-updater/2.0" \
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
    set -- "$@" "--max-latency" "${CFG_max_latency_ms:-0}"
    set -- "$@" "--strict-tcp-count" "${CFG_strict_tcp_count:-0}"
    set -- "$@" "--speed-count" "${CFG_speed_test_count:-1}"
    set -- "$@" "--top" "${CFG_top_per_region:-5}"
    set -- "$@" "--best-top" "${CFG_best_top:-3}"
    set -- "$@" "--tls-timeout" "${CFG_tls_timeout_sec:-3}"
    set -- "$@" "--tls-workers" "${CFG_tls_workers:-8}"
    set -- "$@" "--speed-domain" "${CFG_speed_domain:-speed.cloudflare.com}"
    set -- "$@" "--speed-window" "${CFG_speed_window_sec:-2}"
    if [ -n "${CFG_speed_sni:-}" ]; then set -- "$@" "--sni" "${CFG_speed_sni}"; fi
    if [ -n "${CFG_port_whitelist:-}" ]; then set -- "$@" "--ports" "${CFG_port_whitelist}"; fi
    if [ "${CFG_tls_probe:-1}" != "1" ]; then set -- "$@" "--no-tls-probe"; fi
    set -- "$@" "--show-latency" "${CFG_show_latency:-1}"
    set -- "$@" "--show-mbps" "${CFG_show_bandwidth:-1}"
    set -- "$@" "--fwmark" "${BYPASS_MARK}"

    if [ "${CFG_numbered_regions:-0}" = "1" ]; then set -- "$@" "--numbered"; fi
    if [ "${CFG_verbose:-0}" = "1" ]; then set -- "$@" "--verbose"; fi
    set -- "$@" "--fast-label" "${CFG_fast_label:-优选高速}"

    if [ -n "${CFG_blocked_regions:-}" ]; then 
        set -- "$@" "--blocked-regions" "${CFG_blocked_regions}"
    fi

    set_status "引擎启动中"
    log "Starting V2 speed test engine..."

    if run_python "$@"; then
        log "update.py finished successfully"
    else
        exit_code=$?
        # 退出码 2 = 没有任何节点通过测速，update.py 已保留上一轮结果文件。
        # 这属于"本轮没测到"而不是"插件坏了"，不该报失败、也不该上传空结果。
        if [ "$exit_code" = "2" ]; then
            set_status "无有效节点(沿用上次)"
            log "update.py: 本轮没有节点通过测速，已保留上一轮的 ${FULL_OUTPUT} / ${BEST_OUTPUT}"
            cleanup_proxy_bypass
            run_post_command
            uci -q set cfiptools.config.last_run="$(date '+%Y-%m-%d %H:%M:%S')"
            uci -q set cfiptools.config.last_result="no_valid_node"
            uci -q commit cfiptools
            exit 0
        fi
        set_status "失败"
        log "update.py failed with exit code $exit_code"
        run_post_command
        exit $exit_code
    fi

    cleanup_proxy_bypass
    log "等待 3 秒让代理核心恢复网络环境..."
    sleep 3

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
        export GITHUB_FILE_BEST="${CFG_best_output_file}"
        export GITHUB_FILE_FULL="${CFG_full_output_file}"
        export GITHUB_FILE_README="${CFG_readme_file}"
        export GITHUB_REPO="${CFG_github_repo:-}"
        export GITHUB_BRANCH="${CFG_github_branch:-main}"
        export GITHUB_TOKEN="${CFG_github_token:-}"
        export GITHUB_MESSAGE="${CFG_github_message:-Update IP and README}"
        export GIT_HTTP_PROXY="${CFG_git_http_proxy:-}"
        export GIT_HTTPS_PROXY="${CFG_git_https_proxy:-}"

        if [ -f "$DATA_DIR/github_upload.py" ]; then
            python3 "$DATA_DIR/github_upload.py" >> "$LOG_FILE" 2>&1
            push_exit=$?
            if [ $push_exit -eq 0 ]; then
                log "GitHub upload completed"
            else
                log "GitHub upload failed (exit $push_exit)"
            fi
        else
            log "github_upload.py not found, skip GitHub upload"
        fi
    fi

    ts=$(date '+%Y-%m-%d %H:%M:%S')
    uci -q set cfiptools.config.last_run="$ts"
    uci -q set cfiptools.config.last_result="success"
    uci -q commit cfiptools
    set_status "完成"
    log "All tasks completed"

    run_post_command
}

# 只有没传 cleanup 参数时，才执行测速
if [ -z "$1" ]; then
    run_test
fi