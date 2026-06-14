module("luci.controller.cfiptools", package.seeall)

function index()
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

    local fields = { "cron_schedule", "input_url", "download_timeout", "input_file", "full_output_file", "best_output_file", "tcp_timeout_ms", "tcp_workers", "speed_timeout_sec", "speed_workers", "min_speed_mbps", "max_latency_ms", "strict_tcp_count", "speed_test_count", "top_per_region", "max_nodes", "fast_label", "readme_file", "raw_base_url", "blocked_regions", "github_repo", "github_branch", "github_token", "github_message", "git_http_proxy", "git_https_proxy", "bypass_proxy_method", "pre_test_command", "post_test_command" }

    for _, name in ipairs(fields) do
        local val = luci.http.formvalue(name)
        if val ~= nil then
            if val == "" then cursor:delete("cfiptools", "config", name) else cursor:set("cfiptools", "config", name, val) end
        end
    end

    cursor:commit("cfiptools")
    luci.sys.call("/etc/init.d/cfiptools restart >/dev/null 2>&1")
    luci.sys.call("/etc/init.d/cron reload >/dev/null 2>&1")

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
        local pid = luci.sys.exec("cat " .. pid_file .. " 2>/dev/null"):gsub("%s+", "")
        if pid and pid ~= "" and nixio.fs.access("/proc/" .. pid) then
            local cmdline = luci.sys.exec("cat /proc/" .. pid .. "/cmdline 2>/dev/null") or ""
            if cmdline:match("run%.sh") or cmdline:match("cfiptools") then
                luci.http.prepare_content("application/json")
                luci.http.write_json({status = "already_running", message = "A test is already running"})
                return
            end
        end
    end
    luci.sys.exec("/usr/share/cfiptools/run.sh </dev/null >/dev/null 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "started", message = "Test started"})
end

function action_stop_test()
    luci.sys.exec("echo '--- [INFO] 正在尝试强制终止任务... ---' >> /var/log/cfiptools.log")
    
    -- 终极修复：绝对不能直接 kill -9 run.sh，那会导致绕过防火墙规则残留，毁掉用户网络！
    -- 改为调用 run.sh 内部暴露的专属安全清理通道，让其自己干干净净地退出
    luci.sys.exec("sh /usr/share/cfiptools/run.sh cleanup 2>/dev/null")
    luci.sys.exec("sleep 1") -- 给予代理重置 1 秒钟的喘息时间
    
    -- 强效扫尾：保证没有任何僵尸测速并发进程遗留
    local pids = luci.sys.exec("pgrep -f 'cfiptools' ; pgrep -f 'update.py' ; pgrep -f 'curl'"):gsub("\n", " ")
    if pids ~= "" then
        for pid in pids:gmatch("%S+") do
            luci.sys.exec("kill -9 " .. pid .. " 2>/dev/null")
        end
    end
    
    luci.sys.exec("echo '--- [STOPPED] 任务已强制中断并安全重置代理环境 ---' >> /var/log/cfiptools.log")
    
    luci.sys.exec("rm -f /var/run/cfiptools.pid 2>/dev/null")
    luci.sys.exec("echo '空闲' > /var/run/cfiptools.status 2>/dev/null")
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "stopped", message = "已执行防泄露清理"})
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
        local pid = luci.sys.exec("cat " .. pid_file .. " 2>/dev/null"):gsub("%s+", "")
        if pid and pid ~= "" and nixio.fs.access("/proc/" .. pid) then
            local cmdline = luci.sys.exec("cat /proc/" .. pid .. "/cmdline 2>/dev/null") or ""
            if cmdline:match("run%.sh") or cmdline:match("cfiptools") then
                running = true
            end
        end
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
        log_content = luci.sys.exec("tail -n 1000 " .. log_file .. " 2>/dev/null") or ""
    end
    luci.template.render("cfiptools/log", { log_content = log_content })
end

function action_log_poll()
    local log_file = "/var/log/cfiptools.log"
    local content = ""
    if nixio.fs.access(log_file) then
        content = luci.sys.exec("tail -n 1000 " .. log_file .. " 2>/dev/null") or ""
        content = content:gsub("\r\n", "\n"):gsub("\r$", "")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ content = content })
end

function action_clear_log()
    luci.sys.exec(": > /var/log/cfiptools.log")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "cfiptools", "log_view"))
end

function action_reset()
    luci.sys.exec("sh /usr/share/cfiptools/run.sh cleanup 2>/dev/null")
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
        blocked_regions = "", tcp_timeout_ms = "1500", tcp_workers = "200",
        speed_timeout_sec = "6", speed_workers = "5", min_speed_mbps = "16",
        max_latency_ms = "0", strict_tcp_count = "0", speed_test_count = "1", top_per_region = "5",
        max_nodes = "0", show_latency = "1", show_bandwidth = "1", fast_label = "⚡",
        numbered_regions = "1", verbose = "0", github_upload_enabled = "0", github_repo = "",
        github_branch = "main", github_token = "", github_message = "Update IP and README",
        git_http_proxy = "", git_https_proxy = "", bypass_proxy_method = "env",
        pre_test_command = "", post_test_command = "", last_run = "", last_result = ""
    }

    for k, v in pairs(defaults) do cursor:set("cfiptools", "config", k, v) end
    cursor:commit("cfiptools")
    luci.sys.call("/etc/init.d/cfiptools restart >/dev/null 2>&1")
    luci.sys.call("/etc/init.d/cron reload >/dev/null 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "cfiptools", "main"))
end

function action_read_file()
    local path = luci.http.formvalue("path") or ""
    luci.http.prepare_content("application/json")
    if path == "" then luci.http.write_json({ error = "路径为空" }); return end

    local np = path:gsub("%.%.+/", ""):gsub("/%%.%%.", "")
    local real = nixio.fs.realpath(np)
    
    if not real then 
        luci.http.write_json({ error = "文件不存在或无读取权限" })
        return 
    end

    local allowed = false
    if real:match("^/usr/share/cfiptools/") then
        allowed = true
    else
        local uci = require "luci.model.uci"
        local cursor = uci.cursor()
        local best = cursor:get("cfiptools", "config", "best_output_file")
        local full = cursor:get("cfiptools", "config", "full_output_file")
        local readme = cursor:get("cfiptools", "config", "readme_file")
        
        if (best and real == nixio.fs.realpath(best)) or 
           (full and real == nixio.fs.realpath(full)) or 
           (readme and real == nixio.fs.realpath(readme)) then
            allowed = true
        end
    end

    if not allowed then luci.http.write_json({ error = "路径不被允许读取" }); return end

    if nixio.fs.access(real) then
        local fd = io.open(real, "r")
        if fd then
            local content = fd:read("*a") or ""
            fd:close()
            luci.http.write_json({ content = content })
            return
        end
    end
    luci.http.write_json({ error = "文件读取失败" })
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
    
    -- 提取出自定义文件路径交由 Github 手动上传按钮使用
    local file_best = cursor:get("cfiptools", "config", "best_output_file") or "/usr/share/cfiptools/best_ips.txt"
    local file_full = cursor:get("cfiptools", "config", "full_output_file") or "/usr/share/cfiptools/full_ips.txt"
    local file_readme = cursor:get("cfiptools", "config", "readme_file") or "/usr/share/cfiptools/README.MD"

    luci.http.prepare_content("application/json")
    if repo == "" or token == "" then
        luci.http.write_json({success = false, message = "请先配置并【保存】仓库地址和 Token！"})
        return
    end

    local pid_file = "/var/run/cfiptools.pid"
    if nixio.fs.access(pid_file) then
        local pid = luci.sys.exec("cat " .. pid_file .. " 2>/dev/null"):gsub("%s+", "")
        if pid and pid ~= "" and nixio.fs.access("/proc/" .. pid) then
            luci.http.write_json({success = false, message = "当前有测速任务正在运行，请等待完成后再试！"})
            return
        end
    end

    local function sq(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end
    
    local env_file = "/tmp/.cfiptools_github.env"
    local fd = io.open(env_file, "w")
    if fd then
        fd:write("export ENABLE_GITHUB_UPLOAD='true'\n")
        fd:write("export GITHUB_REPO=" .. sq(repo) .. "\n")
        fd:write("export GITHUB_BRANCH=" .. sq(branch) .. "\n")
        fd:write("export GITHUB_TOKEN=" .. sq(token) .. "\n")
        fd:write("export GITHUB_MESSAGE=" .. sq(msg) .. "\n")
        fd:write("export GIT_HTTP_PROXY=" .. sq(http_proxy) .. "\n")
        fd:write("export GIT_HTTPS_PROXY=" .. sq(https_proxy) .. "\n")
        fd:write("export GITHUB_FILE_BEST=" .. sq(file_best) .. "\n")
        fd:write("export GITHUB_FILE_FULL=" .. sq(file_full) .. "\n")
        fd:write("export GITHUB_FILE_README=" .. sq(file_readme) .. "\n")
        fd:close()
    end

    local cmd = string.format([[(
        echo "上传GitHub" > /var/run/cfiptools.status
        echo "[$(date +'%%Y-%%m-%%d %%H:%%M:%%S')] [手动触发] 开始上传 GitHub..." >> /var/log/cfiptools.log
        . %s
        sh /usr/share/cfiptools/push_results.sh >> /var/log/cfiptools.log 2>&1
        if [ $? -eq 0 ]; then
            echo "[$(date +'%%Y-%%m-%%d %%H:%%M:%%S')] [手动触发] 上传完成" >> /var/log/cfiptools.log
        else
            echo "[$(date +'%%Y-%%m-%%d %%H:%%M:%%S')] [手动触发] 上传失败，请检查日志" >> /var/log/cfiptools.log
        fi
        echo "空闲" > /var/run/cfiptools.status
        rm -f %s
    ) &]], env_file, env_file)

    luci.sys.call(cmd)
    luci.http.write_json({success = true, message = "已触发防注入安全沙盒上传指令！请检查日志。"})
end

function action_main()
    luci.http.header("Content-Security-Policy", "default-src 'self' 'unsafe-inline' 'unsafe-eval' data:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';")
    luci.template.render("cfiptools/main")
end