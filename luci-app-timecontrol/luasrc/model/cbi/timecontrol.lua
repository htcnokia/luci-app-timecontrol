local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local m, s, o

-- 检测Turbo ACC/offload状态
local function check_offload()
    local offload_modules = {
        "xt_FLOWOFFLOAD",
        "nf_flow_table",
        "flow_offload"
    }
    for _, mod in ipairs(offload_modules) do
        if sys.exec("lsmod | grep -q " .. mod) == "" then
            return true
        end
    end
    if sys.exec("uci get turboacc.config.enabled 2>/dev/null") == "1" then
        return true
    end
    return false
end

-- 时间转换工具（分钟数↔时间字符串）
local function time_to_minutes(time_str)
    local h, m = time_str:match("^(%d+):(%d+)$")
    return tonumber(h) * 60 + tonumber(m)
end
local function minutes_to_time(minutes)
    local h = math.floor(minutes / 60)
    local m = minutes % 60
    return string.format("%02d:%02d", h, m)
end

-- 获取所有启用规则的时间窗口（最早开始、最晚结束）
local function get_time_window()
    local min_timeon = nil
    local max_timeoff = nil
    uci:foreach("timecontrol", "macbind", function(section)
        if section.enable == "1" then
            local timeon = section.timeon or "22:00"
            local timeoff = section.timeoff or "06:00"
            local ton = time_to_minutes(timeon)
            local toff = time_to_minutes(timeoff)
            if not min_timeon or ton < min_timeon then min_timeon = ton end
            if not max_timeoff or toff > max_timeoff then max_timeoff = toff end
        end
    end)
    return min_timeon, max_timeoff
end

-- 管理Turbo ACC计划任务（返回执行结果）
local function manage_turbo_tasks()
    local timecontrol_enabled = uci:get("timecontrol", "config", "enabled") or "0"
    local task_comment = "# TimeControl Turbo ACC"
    -- 先清除旧任务，避免重复
    sys.exec("sed -i '/" .. task_comment .. "/d' /etc/crontabs/root")
    
    if timecontrol_enabled ~= "1" then
        sys.exec("/etc/init.d/cron restart")
        return "Time control disabled, all Turbo ACC tasks removed"
    end
    
    local min_timeon, max_timeoff = get_time_window()
    if not min_timeon or not max_timeoff then
        return "No enabled client rules found, no Turbo ACC tasks created"
    end
    
    local start_time = minutes_to_time(min_timeon)
    local end_time = minutes_to_time(max_timeoff)
    local start_h, start_m = start_time:match("^(%d+):(%d+)$")
    local end_h, end_m = end_time:match("^(%d+):(%d+)$")
    
    -- 构建开关命令
    local disable_cmd = string.format(
        "uci set turboacc.config.enabled=0; uci commit turboacc; /etc/init.d/turboacc restart; %s",
        task_comment
    )
    local enable_cmd = string.format(
        "uci set turboacc.config.enabled=1; uci commit turboacc; /etc/init.d/turboacc restart; %s",
        task_comment
    )
    
    -- 添加新任务
    sys.exec(string.format("echo '%s %s * * * %s' >> /etc/crontabs/root", start_m, start_h, disable_cmd))
    sys.exec(string.format("echo '%s %s * * * %s' >> /etc/crontabs/root", end_m, end_h, enable_cmd))
    sys.exec("/etc/init.d/cron restart")
    
    return string.format("Turbo ACC tasks created:\n- Disable at %s (start of control)\n- Enable at %s (end of control)", start_time, end_time)
end

-- 页面标题与警告信息
local warning_msg = translate("Configure internet access time control for network devices")
if check_offload() then
    warning_msg = warning_msg .. "<br/><br/><b style='color:red'>" 
        .. translate("Warning: Turbo ACC/offload detected, may cause iptables rules of this plugin to fail") 
        .. "</b>"
end

-- 主配置映射（提交后自动更新任务）
m = Map("timecontrol", translate("Internet Time Control"), warning_msg)
m.on_after_commit = function(self)
    manage_turbo_tasks()
end

-- ====== 基础设置区域（修复配置类型）======
s = m:section(TypedSection, "basic", translate("Basic Settings"))
s.anonymous = true
s.addremove = false

-- 启用时间控制（修复字段名为 enabled）
o = s:option(Flag, "enabled", translate("Enable Time Control"))
o.rmempty = false
o.default = "0"

-- 嚴格模式
o = s:option(Flag, "strict_mode", translate("Strict Mode"),
    translate("Block ALL traffic including established connections. Recommended for better control."))
o.rmempty = false
o.default = "1"

-- 主机扫描间隔
o = s:option(Value, "scan_interval", translate("Hostname Scan Interval"), 
    translate("Scan interval in minutes (0 to disable automatic scanning)"))
o.datatype = "uinteger"
o.default = "10"
o.rmempty = false

-- ====== 按钮区域（使用SimpleSection独立显示）======
local bs = m:section(SimpleSection)
bs.template = "timecontrol/button_section"

-- ====== 客户端规则区域 ======
s = m:section(TypedSection, "macbind", translate("Client Rules"),
    translate("Configure time-based internet access rules for clients"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"

-- 启用规则
o = s:option(Flag, "enable", translate("Enable"))
o.rmempty = false
o.default = "1"

-- 在 CBI 模型中添加控制模式选择
o = s:option(ListValue, "control_mode", translate("Control Mode"))
o:value("mac", translate("MAC Address (for devices with fixed MAC)"))
o:value("ip", translate("IP Address (for devices with random MAC)"))
o.default = "mac"

-- IP 地址字段
o = s:option(Value, "ipaddr", translate("IP Address"))
o.placeholder = "192.168.1.100"
o:depends("control_mode", "ip")

-- MAC地址选择
o = s:option(Value, "macaddr", translate("MAC Address"))
o.rmempty = true
sys.net.mac_hints(function(mac, name) 
    o:value(mac, "%s (%s)" % {mac, name}) 
end)

-- 主机名
o = s:option(Value, "hostname", translate("Hostname"))
o.rmempty = true
o.placeholder = "e.g., TIZEN"

-- 限制开始/结束时间
o = s:option(Value, "timeon", translate("Block Start Time"))
o.default = "22:30"
o.rmempty = false

o = s:option(Value, "timeoff", translate("Block End Time"))  
o.default = "07:00"
o.rmempty = false

-- 星期选择
o = s:option(Flag, "z1", translate("Mon"))
o.rmempty = true
o.default = "0"

o = s:option(Flag, "z2", translate("Tue"))
o.rmempty = true
o.default = "0"

o = s:option(Flag, "z3", translate("Wed"))
o.rmempty = true
o.default = "0"

o = s:option(Flag, "z4", translate("Thu"))
o.rmempty = true
o.default = "0"

o = s:option(Flag, "z5", translate("Fri"))
o.rmempty = true
o.default = "0"

o = s:option(Flag, "z6", translate("Sat"))
o.rmempty = true
o.default = "0"

o = s:option(Flag, "z7", translate("Sun"))
o.rmempty = true
o.default = "0"

-- 初始化时自动设置任务
manage_turbo_tasks()

return m
