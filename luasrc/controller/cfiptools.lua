module("luci.controller.cfiptools", package.seeall)

function index()
    -- 不再检查配置文件是否存在，始终显示菜单
    entry({"admin", "services", "cfiptools"}, alias("admin", "services", "cfiptools", "main"), _("CFIP优选"), 90)
    entry({"admin", "services", "cfiptools", "main"}, call("action_main"), _("CFIP优选"), 10)
    entry({"admin", "services", "cfiptools", "save"}, call("action_save"))
    entry({"admin", "services", "cfiptools", "start_test"}, call("action_start_test"))
    entry({"admin", "services", "cfiptools", "stop_test"}, call("action_stop_test"))
    entry({"admin", "services", "cfiptools", "get_status"}, call("action_get_status"))
    entry({"admin", "services", "cfiptools", "log_view"}, call("action_log_view"))
    entry({"admin", "services", "cfiptools", "log_poll"}, call("action_log_poll"))
    entry({"admin", "services", "cfiptools", "clear_log"}, call("action_clear_log"))
    entry({"admin", "services", "cfiptools", "reset"}, call("action_reset"))
    entry({"admin", "services", "cfiptools", "read_file"}, call("action_read_file"))
    entry({"admin", "services", "cfiptools", "manual_upload"}, call("action_manual_upload"))
end

function action_save()
    local uci = require "luci.model.uci"
    local cursor = uci.cursor()
    local checkbox_fields = { "enabled", "download_input", "github_upload_enabled", "show_latency", "show_bandwidth", "numbered_regions", "verbose", "update_readme" }

    for _, name in ipairs(checkbox_fields) do
        local val = luci.http.formvalue(name)
        cursor:set("cfiptools", "config", name, val or "0")
    end

    local fields = { "cron_schedule", "input_url", "download_timeout", "input_file", "full_output_file", "best_output_file", "tcp_timeout_ms", "tcp_workers", "speed_timeout_sec", "speed_workers", "min_speed_mbps", "top_per_region", "max_nodes", "fast_label", "readme_file", "raw_base_url", "test_location", "update_frequency", "github_repo", "github_branch", "github_token", "github_message", "git_http_proxy", "git_https_proxy", "bypass_proxy_method", "pre_test_command", "post_test_command" }

    for _, name in ipairs(fields) do
        local val = luci.http.formvalue(name)
        if val ~= nil then
            if val == "" then cursor:delete("cfiptools", "config", name) else cursor:set("cfiptools", "config", name, val) end
        end
    end

    cursor:commit("cfiptools")
    luci.sys.call("/etc/init.d/cfiptools restart >/dev/null 2>&1")
    luci.sys.call("/etc/init.d/cron restart >/dev/null 2>&1")

    if luci.http.formvalue("ajax") == "1" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "ok"})
    else
        luci.http.redirect(luci.dispatcher.build_url("admin", "services", "cfiptools", "main"))
    end
end

function action_start_test()
    local pid_file = "/var/run/cfiptools.pid"
    if nixio.fs.access(pid_file) then
        local pid = tonumber(luci.sys.exec("cat " .. pid_file))
        if pid and luci.sys.process.signal(pid, 0) then
            luci.http.prepare_content("application/json")
            luci.http.write_json({status = "already_running", message = "A test is already running"})
            return
        end
    end
    luci.sys.exec("/usr/share/cfiptools/run.sh </dev/null >/dev/null 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "started", message = "Test started"})
end

function action_stop_test()
    local pid_file = "/var/run/cfiptools.pid"
    if not nixio.fs.access(pid_file) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "not_running", message = "No test is running"})
        return
    end
    local pid = tonumber(luci.sys.exec("cat " .. pid_file))
    if pid then
        luci.sys.exec("kill -TERM " .. pid .. " 2>/dev/null")
        luci.sys.exec("sleep 1")
        luci.sys.exec("kill -KILL " .. pid .. " 2>/dev/null")
    end
    luci.sys.exec("pkill -f '/usr/share/cfiptools/update.py' 2>/dev/null")
    luci.sys.exec("pkill -f 'curl.*speed.cloudflare.com' 2>/dev/null")
    luci.sys.exec("rm -f " .. pid_file)
    luci.sys.exec(": > /var/run/cfiptools.status 2>/dev/null")
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "stopped", message = "Test stopped"})
end

function action_get_status()
    local status_file = "/var/run/cfiptools.status"
    local pid_file = "/var/run/cfiptools.pid"
    local status = "空闲"
    local running = false
    local last_run = ""
    local last_result = ""

    if nixio.fs.access(status_file) then status = luci.sys.exec("cat " .. status_file):match("^(%S+)") or "空闲" end
    if nixio.fs.access(pid_file) then
        local pid = tonumber(luci.sys.exec("cat " .. pid_file))
        if pid and luci.sys.process.signal(pid, 0) then running = true end
    end

    local uci = require "luci.model.uci"
    local cursor = uci.cursor()
    last_run = cursor:get("cfiptools", "config", "last_run") or ""
    last_result = cursor:get("cfiptools", "config", "last_result") or ""

    luci.http.prepare_content("application/json")
    luci.http.write_json({ status = status, running = running, last_run = last_run, last_result = last_result })
end

function action_log_view()
    local log_file = "/var/log/cfiptools.log"
    local log_content = ""
    if nixio.fs.access(log_file) then
        -- 暴力读取原汁原味的日志，保留所有的 \r，不做任何破坏
        log_content = luci.sys.exec("tail -n 1000 " .. log_file .. " 2>/dev/null") or ""
    end
    luci.template.render("cfiptools/log", { log_content = log_content })
end

function action_log_poll()
    local log_file = "/var/log/cfiptools.log"
    local content = ""
    if nixio.fs.access(log_file) then
        -- 暴力读取原汁原味的日志
        content = luci.sys.exec("tail -n 1000 " .. log_file .. " 2>/dev/null") or ""
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ content = content })
end

function action_log_poll()
    local log_file = "/var/log/cfiptools.log"
    local content = ""
    if nixio.fs.access(log_file) then
        local raw = luci.sys.exec("tail -n 500 " .. log_file .. " 2>/dev/null")
        local lines = {}
        for line in raw:gmatch("[^\r\n]+") do table.insert(lines, 1, luci.util.pcdata(line)) end
        content = table.concat(lines, "\n")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ content = content })
end

function action_clear_log()
    luci.sys.exec(": > /var/log/cfiptools.log")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "cfiptools", "log_view"))
end

function action_reset()
    luci.sys.exec("pkill -f 'update.py' 2>/dev/null")
    luci.sys.exec("rm -f /var/run/cfiptools.pid")
    luci.sys.exec(": > /var/run/cfiptools.status 2>/dev/null")
    luci.sys.exec(": > /var/log/cfiptools.log 2>/dev/null")

    local uci = require "luci.model.uci"
    local cursor = uci.cursor()
    cursor:delete("cfiptools", "config")
    cursor:section("cfiptools", "cfiptools", "config")

    local defaults = {
        enabled = "1", cron_schedule = "*/30 * * * *", input_url = "https://zip.cm.edu.kg/all.txt",
        download_input = "1", download_timeout = "30", input_file = "/usr/share/cfiptools/ips.txt",
        full_output_file = "/usr/share/cfiptools/full_ips.txt", best_output_file = "/usr/share/cfiptools/best_ips.txt",
        update_readme = "1", readme_file = "/usr/share/cfiptools/README.MD", raw_base_url = "",
        test_location = "", update_frequency = "", tcp_timeout_ms = "500", tcp_workers = "200",
        speed_timeout_sec = "6", speed_workers = "5", min_speed_mbps = "16", top_per_region = "10",
        max_nodes = "0", show_latency = "1", show_bandwidth = "1", fast_label = "⚡",
        numbered_regions = "1", verbose = "0", github_upload_enabled = "0", github_repo = "",
        github_branch = "main", github_token = "", github_message = "Update IP and README",
        git_http_proxy = "", git_https_proxy = "", bypass_proxy_method = "nftables",
        pre_test_command = "", post_test_command = "", last_run = "", last_result = ""
    }

    for k, v in pairs(defaults) do cursor:set("cfiptools", "config", k, v) end
    cursor:commit("cfiptools")
    luci.sys.call("/etc/init.d/cfiptools restart >/dev/null 2>&1")
    luci.sys.call("/etc/init.d/cron restart >/dev/null 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "cfiptools", "main"))
end

-- 安全的文件读取，防路径遍历
function action_read_file()
    local path = luci.http.formvalue("path") or ""
    luci.http.prepare_content("application/json")
    if path == "" then luci.http.write_json({ error = "路径为空" }); return end

    -- 规范化路径（移除可能的上层目录引用）
    local function safe_path(p)
        -- 移除 ../ 和 ..\ 以及 URL 编码
        local np = p:gsub("%.%.+/", ""):gsub("/%%.%%.", "")
        return np
    end

    local safe = safe_path(path)
    -- 白名单：仅允许 /usr/share/cfiptools/ 下的文件，或者配置中的输出文件
    local allowed = false
    if safe:match("^/usr/share/cfiptools/") then
        allowed = true
    else
        local uci = require "luci.model.uci"
        local cursor = uci.cursor()
        local best = cursor:get("cfiptools", "config", "best_output_file")
        local full = cursor:get("cfiptools", "config", "full_output_file")
        local readme = cursor:get("cfiptools", "config", "readme_file")
        if (best and safe == best) or (full and safe == full) or (readme and safe == readme) then
            allowed = true
        end
    end

    if not allowed then luci.http.write_json({ error = "路径不被允许" }); return end

    -- 额外检查：最终路径不能包含 ..
    if safe:find("%.%.", 1, true) then
        luci.http.write_json({ error = "非法路径" }); return
    end

    if nixio.fs.access(safe) then
        local fd = io.open(safe, "r")
        if fd then
            local content = fd:read("*a") or ""
            fd:close()
            luci.http.write_json({ content = content })
            return
        end
    end
    luci.http.write_json({ error = "文件不存在或无读取权限" })
end

function action_manual_upload()
    local uci = require "luci.model.uci"
    local cursor = uci.cursor()
    local repo = cursor:get("cfiptools", "config", "github_repo") or ""
    local branch = cursor:get("cfiptools", "config", "github_branch") or "main"
    local token = cursor:get("cfiptools", "config", "github_token") or ""
    local msg = cursor:get("cfiptools", "config", "github_message") or "Manual Update IP"
    local http_proxy = cursor:get("cfiptools", "config", "git_http_proxy") or ""
    local https_proxy = cursor:get("cfiptools", "config", "git_https_proxy") or ""

    luci.http.prepare_content("application/json")
    if repo == "" or token == "" then
        luci.http.write_json({success = false, message = "请先配置并【保存】仓库地址和 Token！"})
        return
    end

    local pid_file = "/var/run/cfiptools.pid"
    if nixio.fs.access(pid_file) then
        local pid = tonumber(luci.sys.exec("cat " .. pid_file))
        if pid and luci.sys.process.signal(pid, 0) then
            luci.http.write_json({success = false, message = "当前有测速任务正在运行，请等待完成后再试！"})
            return
        end
    end

    local function sq(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end
    local cmd = string.format([[
        (
            echo "上传GitHub" > /var/run/cfiptools.status
            echo "[$(date +'%%Y-%%m-%%d %%H:%%M:%%S')] [手动触发] 开始上传 GitHub..." >> /var/log/cfiptools.log
            export ENABLE_GITHUB_UPLOAD="true"
            export GITHUB_REPO=%s
            export GITHUB_BRANCH=%s
            export GITHUB_TOKEN=%s
            export GITHUB_MESSAGE=%s
            export GIT_HTTP_PROXY=%s
            export GIT_HTTPS_PROXY=%s

            sh /usr/share/cfiptools/push_results.sh >> /var/log/cfiptools.log 2>&1

            if [ $? -eq 0 ]; then
                echo "[$(date +'%%Y-%%m-%%d %%H:%%M:%%S')] [手动触发] 上传完成" >> /var/log/cfiptools.log
            else
                echo "[$(date +'%%Y-%%m-%%d %%H:%%M:%%S')] [手动触发] 上传失败，请检查日志" >> /var/log/cfiptools.log
            fi
            echo "空闲" > /var/run/cfiptools.status
        ) &
    ]], sq(repo), sq(branch), sq(token), sq(msg), sq(http_proxy), sq(https_proxy))

    luci.sys.exec(cmd)
    luci.http.write_json({success = true, message = "已触发上传指令！将为您跳转到日志页面..."})
end

function action_main()
    luci.http.header("Content-Security-Policy", "default-src 'self' 'unsafe-inline' 'unsafe-eval' data:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';")
    luci.template.render("cfiptools/main")
end