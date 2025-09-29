#!/bin/bash
rm -rf ./package/luci-app-timecontrol
# 创建目录结构
mkdir -p ./package/luci-app-timecontrol/luasrc/controller
mkdir -p ./package/luci-app-timecontrol/luasrc/view/timecontrol
mkdir -p ./package/luci-app-timecontrol/luasrc/model/cbi
mkdir -p ./package/luci-app-timecontrol/root/etc/config
mkdir -p ./package/luci-app-timecontrol/root/etc/uci-defaults
mkdir -p ./package/luci-app-timecontrol/root/etc/init.d
mkdir -p ./package/luci-app-timecontrol/root/usr/share/rpcd/acl.d
mkdir -p ./package/luci-app-timecontrol/po/pl
mkdir -p ./package/luci-app-timecontrol/po/zh_Hans
mkdir -p ./package/luci-app-timecontrol/po/zh-cn

echo "Creating default config file..."

# ★★★ 创建默认UCI配置文件 ★★★
cat << 'EOF' > ./package/luci-app-timecontrol/root/etc/config/timecontrol
# Time Control Configuration

config basic 'config'
	option enabled '0'
	option scan_interval '10'

EOF

echo "Creating controller file..."

# 创建控制器文件
cat << 'EOF' > ./package/luci-app-timecontrol/luasrc/controller/timecontrol.lua
module("luci.controller.timecontrol", package.seeall)

function index()
    -- 主配置页面
    entry({"admin", "services", "timecontrol"}, cbi("timecontrol"), _("Internet Time Control"), 60).dependent = true
    entry({"admin", "services", "timecontrol", "turbo_process"}, call("action_turbo_process")).leaf = true
    entry({"admin", "services", "timecontrol", "scan"}, call("action_scan")).leaf = true
end

-- Turbo ACC任务处理逻辑
function action_turbo_process()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    
    local function time_to_minutes(time_str)
        local h, m = time_str:match("^(%d+):(%d+)$")
        return tonumber(h) * 60 + tonumber(m)
    end
    
    local function minutes_to_time(minutes)
        local h = math.floor(minutes / 60)
        local m = minutes % 60
        return string.format("%02d:%02d", h, m)
    end
    
    local function get_time_window()
        local min_timeon = nil
        local max_timeoff = nil
        uci:foreach("timecontrol", "macbind", function(section)
            if section.enable == "1" then
                local timeon = section.timeon or "22:30"
                local timeoff = section.timeoff or "07:00"
                local ton = time_to_minutes(timeon)
                local toff = time_to_minutes(timeoff)
                if not min_timeon or ton < min_timeon then min_timeon = ton end
                if not max_timeoff or toff > max_timeoff then max_timeoff = toff end
            end
        end)
        return min_timeon, max_timeoff
    end
    
    -- 执行任务并返回结果
    local timecontrol_enabled = uci:get("timecontrol", "config", "enabled") or "0"
    local task_comment = "# TimeControl Turbo ACC"
    sys.exec("sed -i '/" .. task_comment .. "/d' /etc/crontabs/root")
    
    local result = ""
    if timecontrol_enabled ~= "1" then
        sys.exec("/etc/init.d/cron restart")
        result = "Time control disabled, all Turbo ACC tasks removed"
    else
        local min_timeon, max_timeoff = get_time_window()
        if not min_timeon or not max_timeoff then
            result = "No enabled client rules found, no Turbo ACC tasks created"
        else
            local start_time = minutes_to_time(min_timeon)
            local end_time = minutes_to_time(max_timeoff)
            local start_h, start_m = start_time:match("^(%d+):(%d+)$")
            local end_h, end_m = end_time:match("^(%d+):(%d+)$")
            
            local disable_cmd = string.format(
                "uci set turboacc.config.enabled=0; uci commit turboacc; /etc/init.d/turboacc restart; %s",
                task_comment
            )
            local enable_cmd = string.format(
                "uci set turboacc.config.enabled=1; uci commit turboacc; /etc/init.d/turboacc restart; %s",
                task_comment
            )
            
            sys.exec(string.format("echo '%s %s * * * %s' >> /etc/crontabs/root", start_m, start_h, disable_cmd))
            sys.exec(string.format("echo '%s %s * * * %s' >> /etc/crontabs/root", end_m, end_h, enable_cmd))
            sys.exec("/etc/init.d/cron restart")
            
            result = string.format("Turbo ACC tasks created:\n- Disable at %s (start of control)\n- Enable at %s (end of control)", start_time, end_time)
        end
    end
    
    -- 返回结果（纯文本，避免乱码）
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(result)
end

-- ★★★ scan接口 ★★★
function action_scan()
    local sys = require "luci.sys"
    
    -- 执行扫描并获取输出
    local output = sys.exec("/etc/init.d/timecontrol scan showlogs 2>&1")
    
    local e = {}
    e.output = output
    e.success = (output:match("updated") ~= nil) or (output:match("No updates needed") ~= nil)
    
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

function status()
	local e = {}
	e.status = (luci.sys.call("iptables -L FORWARD 2>/dev/null | grep -q TIMECONTROL") == 0)
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
EOF

echo "Creating CBI model file..."

# ★★★ CBI模型 ★★★
cat << 'EOF' > ./package/luci-app-timecontrol/luasrc/model/cbi/timecontrol.lua
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

-- ====== 基础设置区域 ======
s = m:section(TypedSection, "basic", translate("Basic Settings"))
s.anonymous = true
s.addremove = false

-- 启用时间控制
o = s:option(Flag, "enabled", translate("Enable Time Control"))
o.rmempty = false
o.default = "0"

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
EOF

echo "Creating view template files..."

# ★★★ 创建简化的按钮区域模板 ★★★
cat << 'EOF' > ./package/luci-app-timecontrol/luasrc/view/timecontrol/button_section.htm
<style>
.tc-button-group {
    display: flex;
    gap: 12px;
    margin: 20px 0;
    flex-wrap: wrap;
    align-items: center;
}
.tc-button-group .cbi-button {
    padding: 8px 20px;
    min-width: 140px;
}
.tc-result {
    width: 100%;
    margin-top: 15px;
    padding: 12px 15px;
    border-radius: 4px;
    white-space: pre-wrap;
    font-family: monospace;
    font-size: 13px;
    display: none;
}
</style>

<div class="cbi-section">
    <div class="cbi-section-node">
        <div class="tc-button-group">
            <input class="cbi-button cbi-button-apply" type="button" 
                   value="<%:Scan Now%>" onclick="tcScanHostnames()" id="tc-scan-btn" />
            
            <input class="cbi-button cbi-button-apply" type="button" 
                   value="<%:Process Turbo ACC%>" onclick="tcHandleTurbo()" id="tc-turbo-btn" />
        </div>
        
        <div id="tc-result" class="tc-result"></div>
    </div>
</div>

<script type="text/javascript">
// 扫描主机名功能
function tcScanHostnames() {
    var btn = document.getElementById('tc-scan-btn');
    var result = document.getElementById('tc-result');
    
    btn.disabled = true;
    btn.value = '<%:Scanning...%>';
    result.style.display = 'none';
    
    XHR.get('<%=url("admin/services/timecontrol/scan")%>', null,
        function(x, data) {
            btn.disabled = false;
            btn.value = '<%:Scan Now%>';
            
            if (data && data.output) {
                result.innerHTML = data.output.replace(/\n/g, '<br>');
                result.style.display = 'block';
                result.style.border = '1px solid ' + (data.success ? '#5cb85c' : '#d9534f');
                result.style.backgroundColor = data.success ? '#dff0d8' : '#f2dede';
                
                // 如果有更新，5秒后刷新页面
                if (data.success && data.output.indexOf('updated') >= 0) {
                    setTimeout(function() {
                        window.location.reload();
                    }, 5000);
                }
            } else {
                result.innerHTML = '<%:Scan failed%>';
                result.style.display = 'block';
                result.style.border = '1px solid #d9534f';
                result.style.backgroundColor = '#f2dede';
            }
        }
    );
}

// 处理Turbo ACC任务
function tcHandleTurbo() {
    var btn = document.getElementById('tc-turbo-btn');
    var result = document.getElementById('tc-result');
    
    btn.disabled = true;
    btn.value = '<%:Processing...%>';
    result.style.display = 'none';
    
    fetch('<%=luci.dispatcher.build_url("admin", "services", "timecontrol", "turbo_process")%>')
        .then(function(response) {
            if (!response.ok) throw new Error('Network error');
            return response.text();
        })
        .then(function(text) {
            result.innerHTML = '<strong><%:Turbo ACC Result:%></strong><br>' + text.replace(/\n/g, '<br>');
            result.style.display = 'block';
            result.style.border = '1px solid #5cb85c';
            result.style.backgroundColor = '#dff0d8';
            btn.disabled = false;
            btn.value = '<%:Process Turbo ACC%>';
        })
        .catch(function(error) {
            result.innerHTML = '<strong><%:Error:%></strong> <%:Failed to process Turbo ACC%>';
            result.style.display = 'block';
            result.style.border = '1px solid #d9534f';
            result.style.backgroundColor = '#f2dede';
            btn.disabled = false;
            btn.value = '<%:Process Turbo ACC%>';
        });
}
</script>
EOF

cat << 'EOF' > ./package/luci-app-timecontrol/luasrc/view/timecontrol/timecontrol.htm
<%+cbi/valueheader%>
<span id="timecontrol-status" style="font-weight:bold;"><%:Collecting data...%></span>
<script type="text/javascript">
	XHR.poll(3, '<%=url("admin/services/timecontrol/status")%>', null,
		function(x, result) {
			var status = document.getElementById('timecontrol-status');
			if (status && result) {
				status.style.color = result.status ? 'green' : 'red';
				status.innerHTML = result.status ? '<%:Running%>' : '<%:Not Running%>';
			}
		}
	);
</script>
<%+cbi/valuefooter%>
EOF

cat << 'EOF' > ./package/luci-app-timecontrol/luasrc/view/timecontrol/index.htm
<%+header%>
<div class="cbi-section">
	<div class="cbi-section-node">
		<div class="cbi-value">
			<label class="cbi-value-title"><%:Status%>:</label>
			<div class="cbi-value-field">
				<span id="service-status" style="font-weight:bold;"><%:Collecting data...%></span>
			</div>
		</div>
	</div>
</div>
<%- include("cbi/map") -%>
<script type="text/javascript">
	XHR.poll(3, '<%=url("admin/services/timecontrol/status")%>', null,
		function(x, result) {
			var status = document.getElementById('service-status');
			if (status && result) {
				status.style.color = result.status ? 'green' : 'red';
				status.innerHTML = result.status ? '<%:Running%>' : '<%:Not Running%>';
			}
		}
	);
</script>
<%+footer%>
EOF

echo "Creating uci-defaults script..."

# 创建uci-defaults脚本
cat << 'EOF' > ./package/luci-app-timecontrol/root/etc/uci-defaults/luci-app-timecontrol
#!/bin/sh

uci -q batch <<-EOF01 >/dev/null
	delete firewall.timecontrol
	set firewall.timecontrol=include
	set firewall.timecontrol.type=script
	set firewall.timecontrol.path=/var/etc/timecontrol.include
	set firewall.timecontrol.reload=1
EOF01

uci -q batch <<-EOF02 >/dev/null
	delete ucitrack.@timecontrol[-1]
	add ucitrack timecontrol
	set ucitrack.@timecontrol[-1].init=timecontrol
	commit ucitrack
EOF02

# ★★★ 关键修复5：初始化配置文件 ★★★
if [ ! -f /etc/config/timecontrol ]; then
    touch /etc/config/timecontrol
    uci -q batch <<-EOF03 >/dev/null
        set timecontrol.config=basic
        set timecontrol.config.enabled='0'
        set timecontrol.config.scan_interval='10'
        commit timecontrol
EOF03
fi

rm -rf /tmp/luci-*cache
exit 0
EOF

echo "Creating init.d script..."

# ★★★ init.d脚本中的uci读取 ★★★
cat << 'INITEOF' > ./package/luci-app-timecontrol/root/etc/init.d/timecontrol
#!/bin/sh /etc/rc.common

START=99
CONFIG=timecontrol

# 注册额外命令（关键添加部分）
EXTRA_COMMANDS="scan"
EXTRA_HELP="       scan            Scan and update MAC addresses (add 'showlogs' for detailed output)"

uci_get_by_type() {
	local index=0
	[ -n $4 ] && index=$4
	local ret=$(uci -q get $CONFIG.@$1[$index].$2 2>/dev/null)
	echo ${ret:=$3}
}

# 通过hostname查找MAC地址 - 增强调试输出
get_mac_by_hostname() {
	local hostname="$1"
	local showlogs="$2"
	local mac=""
	
	# 日志输出重定向到stderr（>&2），避免混入MAC结果
	[ "$showlogs" = "showlogs" ] && echo "Searching MAC for hostname: $hostname" >&2
	
	# 首先尝试从 /tmp/dhcp.leases 查找
	if [ -f "/tmp/dhcp.leases" ]; then
		mac=$(awk -v host="$hostname" 'tolower($4) == tolower(host) {print toupper($2)}' /tmp/dhcp.leases | head -n1)
		[ "$showlogs" = "showlogs" ] && [ -n "$mac" ] && echo "  Found in dhcp.leases: $mac" >&2
	fi
	
	# 如果没找到，尝试从 ARP 表查找（通过主机名）
	if [ -z "$mac" ]; then
		[ "$showlogs" = "showlogs" ] && echo "  Not found in dhcp.leases, trying ping..." >&2
		ping -c 1 -W 1 "$hostname" >/dev/null 2>&1
		mac=$(arp -n | awk '{print toupper($3)}' | grep -E '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' | head -n1)
		[ "$showlogs" = "showlogs" ] && [ -n "$mac" ] && echo "  Found via ping/arp: $mac" >&2
	fi
	
	# 尝试通过nslookup解析IP后查找
	if [ -z "$mac" ]; then
		[ "$showlogs" = "showlogs" ] && echo "  Trying DNS lookup..." >&2
		local ip=$(nslookup "$hostname" 2>/dev/null | awk '/^Address.*: [0-9]/ {print $NF}' | grep -v "127.0.0.1" | head -n1)
		if [ -n "$ip" ]; then
			[ "$showlogs" = "showlogs" ] && echo "  Resolved IP: $ip" >&2
			ping -c 1 -W 1 "$ip" >/dev/null 2>&1
			mac=$(arp -n | awk -v ip="$ip" '$1 == ip {print toupper($3)}' | head -n1)
			[ "$showlogs" = "showlogs" ] && [ -n "$mac" ] && echo "  Found via IP/ARP: $mac" >&2
		fi
	fi
	
	# 最后尝试直接从ARP表匹配主机名
	if [ -z "$mac" ]; then
		[ "$showlogs" = "showlogs" ] && echo "  Checking ARP table directly..." >&2
		mac=$(arp -a | grep -i "$hostname" | awk -F'[()]' '{print $2}' | xargs -I{} arp -n {} 2>/dev/null | awk '{print toupper($3)}' | grep -E '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' | head -n1)
		[ "$showlogs" = "showlogs" ] && [ -n "$mac" ] && echo "  Found in ARP table: $mac" >&2
	fi
	
	[ "$showlogs" = "showlogs" ] && [ -z "$mac" ] && echo "  WARNING: MAC not found for $hostname" >&2
	
	# 仅输出MAC地址（标准输出），供外部变量捕获
	echo "$mac"
}

# 检查字符串是否为MAC地址格式
is_mac_address() {
	local addr="$1"
	echo "$addr" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
	return $?
}

# 扫描并更新hostname对应的MAC地址 - 添加详细日志
scan_and_update_mac() {
	local showlogs="$1"
	local updated=0
	local count=$(uci show $CONFIG 2>/dev/null | grep "=macbind" | wc -l)
	
	if [ "$count" -eq 0 ]; then
		[ "$showlogs" = "showlogs" ] && echo "No macbind entries found in configuration"
		return 1
	fi
	
	count=$((count - 1))
	[ "$showlogs" = "showlogs" ] && echo "========================================="
	[ "$showlogs" = "showlogs" ] && echo "Starting hostname scan..."
	[ "$showlogs" = "showlogs" ] && echo "Found $((count + 1)) macbind entries"
	[ "$showlogs" = "showlogs" ] && echo "========================================="
	
	# 遍历所有macbind配置
	for i in $(seq 0 $count); do
		local enable=$(uci -q get $CONFIG.@macbind[$i].enable)
		local macaddr=$(uci -q get $CONFIG.@macbind[$i].macaddr)
		local hostname=$(uci -q get $CONFIG.@macbind[$i].hostname)
		
		# 跳过未启用或无效的条目
		if [ "$enable" != "1" ]; then
			[ "$showlogs" = "showlogs" ] && echo ""
			[ "$showlogs" = "showlogs" ] && echo "Entry #$i: DISABLED - skipping"
			continue
		fi
		
		if [ -z "$macaddr" ]; then
			[ "$showlogs" = "showlogs" ] && echo ""
			[ "$showlogs" = "showlogs" ] && echo "Entry #$i: No MAC address - skipping"
			continue
		fi
		
		# 只处理有hostname的条目
		if [ -n "$hostname" ]; then
			[ "$showlogs" = "showlogs" ] && echo ""
			[ "$showlogs" = "showlogs" ] && echo "Entry #$i: Checking hostname '$hostname'"
			[ "$showlogs" = "showlogs" ] && echo "  Current MAC: $macaddr"
			
			local new_mac=$(get_mac_by_hostname "$hostname" "$showlogs")
			
			if [ -n "$new_mac" ]; then
				# MAC地址规范化为大写
				macaddr=$(echo "$macaddr" | tr 'a-z' 'A-Z')
				new_mac=$(echo "$new_mac" | tr 'a-z' 'A-Z')
				
				if [ "$new_mac" != "$macaddr" ]; then
					[ "$showlogs" = "showlogs" ] && echo "  >>> MAC CHANGED: $macaddr -> $new_mac <<<"
					uci set $CONFIG.@macbind[$i].macaddr="$new_mac"
					updated=1
					logger -t timecontrol "MAC updated for $hostname: $macaddr -> $new_mac"
				else
					[ "$showlogs" = "showlogs" ] && echo "  MAC unchanged (already correct)"
				fi
			else
				[ "$showlogs" = "showlogs" ] && echo "  !!! WARNING: Could not find MAC address for hostname '$hostname' !!!"
				logger -t timecontrol "Warning: Could not find MAC address for hostname: $hostname"
			fi
		else
			[ "$showlogs" = "showlogs" ] && echo ""
			[ "$showlogs" = "showlogs" ] && echo "Entry #$i: MAC=$macaddr, no hostname saved - skipping"
		fi
	done
	
	# 如果有更新，提交更改
	[ "$showlogs" = "showlogs" ] && echo ""
	[ "$showlogs" = "showlogs" ] && echo "========================================="
	if [ "$updated" -eq 1 ]; then
		uci commit $CONFIG
		[ "$showlogs" = "showlogs" ] && echo "Configuration updated - reloading service..."
		logger -t timecontrol "Configuration updated, $updated entries changed"
		return 0
	else
		[ "$showlogs" = "showlogs" ] && echo "No updates needed - all MACs are current"
		return 1
	fi
}

# 设置定时任务
setup_cron_job() {
	local scan_interval=$(uci_get_by_type basic scan_interval 0)
	
	# 删除现有的定时任务
	crontab -l 2>/dev/null | grep -v "/etc/init.d/timecontrol scan" | crontab -
	
	# 如果间隔大于0，添加新的定时任务
	if [ "$scan_interval" -gt 0 ]; then
		(crontab -l 2>/dev/null; echo "*/$scan_interval * * * * /etc/init.d/timecontrol scan >/dev/null 2>&1") | crontab -
		echo "Cron job set for every $scan_interval minutes"
	else
		echo "Automatic scanning disabled (interval = 0)"
	fi
}

# 移除定时任务
remove_cron_job() {
	crontab -l 2>/dev/null | grep -v "/etc/init.d/timecontrol scan" | crontab -
	echo "Cron job removed"
}

add_rule(){
	local count=$(uci show $CONFIG 2>/dev/null | grep "=macbind" | wc -l)
	[ "$count" -eq 0 ] && {
		echo "No rules to add"
		return
	}
	
	count=$((count - 1))
	
	for i in $(seq 0 $count); do
		local enable=$(uci -q get $CONFIG.@macbind[$i].enable)
		local macaddr=$(uci -q get $CONFIG.@macbind[$i].macaddr)
		local timeoff=$(uci -q get $CONFIG.@macbind[$i].timeoff)
		local timeon=$(uci -q get $CONFIG.@macbind[$i].timeon)
		local z1=$(uci -q get $CONFIG.@macbind[$i].z1)
		local z2=$(uci -q get $CONFIG.@macbind[$i].z2)
		local z3=$(uci -q get $CONFIG.@macbind[$i].z3)
		local z4=$(uci -q get $CONFIG.@macbind[$i].z4)
		local z5=$(uci -q get $CONFIG.@macbind[$i].z5)
		local z6=$(uci -q get $CONFIG.@macbind[$i].z6)
		local z7=$(uci -q get $CONFIG.@macbind[$i].z7)
		
		[ "$z1" == "1" ] && local Z1="Mon,"
		[ "$z2" == "1" ] && local Z2="Tue,"
		[ "$z3" == "1" ] && local Z3="Wed,"
		[ "$z4" == "1" ] && local Z4="Thu,"
		[ "$z5" == "1" ] && local Z5="Fri,"
		[ "$z6" == "1" ] && local Z6="Sat,"
		[ "$z7" == "1" ] && local Z7="Sun"
		
		if [ -z "$enable" ] || [ -z "$macaddr" ] || [ -z "$timeoff" ] || [ -z "$timeon" ]; then
			continue
		fi
		
		# 只处理MAC地址格式的条目
		if [ "$enable" == "1" ] && is_mac_address "$macaddr"; then
			iptables -t filter -I TIMECONTROL -m mac --mac-source $macaddr -m time --kerneltz --timestart $timeon --timestop $timeoff --weekdays $Z1$Z2$Z3$Z4$Z5$Z6$Z7 -j DROP
			iptables -t nat -I PREROUTING 1 -m mac --mac-source $macaddr -m time --kerneltz --timestart $timeon --timestop $timeoff --weekdays $Z1$Z2$Z3$Z4$Z5$Z6$Z7 -m comment --comment "TIMECONTROL" -j RETURN
		fi
	done
	
	echo "/etc/init.d/timecontrol restart" > "/var/etc/timecontrol.include"
}

del_rule(){
	nums=$(iptables -t nat -n -L PREROUTING 2>/dev/null | grep -c "TIMECONTROL")
	if [ -n "$nums" ]; then
		until [ "$nums" = 0 ]
		do
			rules=$(iptables -t nat -n -L PREROUTING --line-num 2>/dev/null | grep "TIMECONTROL" | awk '{print $1}')
			for rule in $rules
			do
				iptables -t nat -D PREROUTING $rule 2>/dev/null
				break
			done
			nums=$(expr $nums - 1)
		done
	fi
}

start(){
	ENABLED=$(uci_get_by_type basic enabled 0)
	[ "$ENABLED" != "1" ] && exit 0
	
	# 设置定时任务
	setup_cron_job
	
	iptables -t filter -N TIMECONTROL
	iptables -t filter -I FORWARD -j TIMECONTROL
	add_rule
}

stop(){
	# 移除定时任务
	remove_cron_job
	
	iptables -t filter -D FORWARD -j TIMECONTROL 2>/dev/null
	iptables -t filter -F TIMECONTROL 2>/dev/null
	iptables -t filter -X TIMECONTROL 2>/dev/null
	del_rule
}

# 扫描功能 - 支持showlogs参数
scan(){
	local showlogs="$1"
	
	if [ "$showlogs" = "showlogs" ]; then
		echo "========================================="
		echo "Timecontrol Hostname Scan"
		echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "========================================="
	else
		logger -t timecontrol "Starting hostname to MAC scan"
	fi
	
	if scan_and_update_mac "$showlogs"; then
		if [ "$showlogs" = "showlogs" ]; then
			echo "Reloading service..."
		fi
		stop
		start
		if [ "$showlogs" = "showlogs" ]; then
			echo "========================================="
			echo "Scan and reload completed successfully!"
			echo "========================================="
		fi
		logger -t timecontrol "Scan and reload completed successfully"
		return 0
	else
		if [ "$showlogs" = "showlogs" ]; then
			echo "========================================="
		fi
		logger -t timecontrol "Scan completed, no reload needed"
		return 1
	fi
}

# reload功能
reload(){
	echo "Reloading timecontrol service..."
	stop
	start
	echo "Reload completed"
}
INITEOF

echo "Creating RPCD ACL file..."

# 创建RPCD ACL文件
cat << 'EOF' > ./package/luci-app-timecontrol/root/usr/share/rpcd/acl.d/luci-app-timecontrol.json
{
	"luci-app-timecontrol": {
		"description": "Grant UCI access for luci-app-timecontrol",
		"read": {
			"uci": [ "timecontrol" ]
		},
		"write": {
			"uci": [ "timecontrol" ]
		}
	}
}
EOF

echo "Creating translation files..."

# 创建翻译文件 - 波兰语
cat << 'EOF' > ./package/luci-app-timecontrol/po/pl/timecontrol.po
msgid ""
msgstr "Content-Type: text/plain; charset=UTF-8\n"

msgid "Internet Time Control"
msgstr "Kontrola czasu w internecie"

msgid "Enable Time Control"
msgstr "Włącz kontrolę czasu"

msgid "Hostname Scan Interval"
msgstr "Interwał skanowania nazw hostów"

msgid "Scan interval in minutes (0 to disable automatic scanning)"
msgstr "Interwał skanowania w minutach (0 aby wyłączyć)"

msgid "Scan Hostnames Now"
msgstr "Skanuj nazwy hostów teraz"

msgid "Scan Now"
msgstr "Skanuj teraz"

msgid "Scanning..."
msgstr "Skanowanie..."

msgid "Scan failed"
msgstr "Skanowanie nieudane"

msgid "Client Rules"
msgstr "Reguły klientów"

msgid "Configure time-based internet access rules for clients"
msgstr "Konfiguruj czasowe reguły dostępu do internetu"

msgid "Enable"
msgstr "Włącz"

msgid "MAC Address"
msgstr "Adres MAC"

msgid "Hostname"
msgstr "Nazwa hosta"

msgid "Block Start Time"
msgstr "Czas rozpoczęcia blokady"

msgid "Block End Time"
msgstr "Czas zakończenia blokady"

msgid "Mon"
msgstr "Pn"

msgid "Tue"
msgstr "Wt"

msgid "Wed"
msgstr "Śr"

msgid "Thu"
msgstr "Czw"

msgid "Fri"
msgstr "Pt"

msgid "Sat"
msgstr "Sob"

msgid "Sun"
msgstr "Ndz"

msgid "Running"
msgstr "Działa"

msgid "Not Running"
msgstr "Nie działa"

msgid "Status"
msgstr "Status"

msgid "Collecting data..."
msgstr "Zbieranie danych..."

msgid "Basic Settings"
msgstr "Ustawienia podstawowe"

msgid "Configure internet access time control for network devices"
msgstr "Konfiguruj kontrolę czasu dostępu do internetu dla urządzeń"

msgid "Warning: Turbo ACC/offload detected, may cause iptables rules of this plugin to fail"
msgstr "Ostrzeżenie: Wykryto Turbo ACC/offload, może powodować niepowodzenie reguł iptables"

msgid "Process Turbo ACC"
msgstr "Przetwórz Turbo ACC"

msgid "Processing..."
msgstr "Przetwarzanie..."

msgid "Turbo ACC Result:"
msgstr "Wynik Turbo ACC:"

msgid "Error:"
msgstr "Błąd:"

msgid "Failed to process Turbo ACC"
msgstr "Nie udało się przetworzyć Turbo ACC"
EOF

# 创建翻译文件 - 简体中文
cat << 'EOF' > ./package/luci-app-timecontrol/po/zh_Hans/timecontrol.po
msgid ""
msgstr "Content-Type: text/plain; charset=UTF-8\n"

msgid "Internet Time Control"
msgstr "上网时间控制"

msgid "Enable Time Control"
msgstr "启用时间控制"

msgid "Warning: Turbo ACC/offload detected, may cause iptables rules of this plugin to fail"
msgstr "警告：检测到启用了类似 Turbo ACC (flow offload)的功能，这会导致本插件的 iptables 规则失效。"

msgid "Hostname Scan Interval"
msgstr "主机名扫描间隔"

msgid "Scan interval in minutes (0 to disable automatic scanning)"
msgstr "扫描间隔分钟数（0表示禁用自动扫描）"

msgid "Scan Hostnames Now"
msgstr "立即扫描主机名"

msgid "Scan Now"
msgstr "立即扫描"

msgid "Scanning..."
msgstr "正在扫描..."

msgid "Scan failed"
msgstr "扫描失败"

msgid "Client Rules"
msgstr "客户端规则"

msgid "Configure time-based internet access rules for clients"
msgstr "为客户端配置基于时间的上网控制规则"

msgid "Enable"
msgstr "启用"

msgid "MAC Address"
msgstr "MAC地址"

msgid "Hostname"
msgstr "主机名"

msgid "Block Start Time"
msgstr "禁止上网开始时间"

msgid "Block End Time"
msgstr "禁止上网结束时间"

msgid "Mon"
msgstr "周一"

msgid "Tue"
msgstr "周二"

msgid "Wed"
msgstr "周三"

msgid "Thu"
msgstr "周四"

msgid "Fri"
msgstr "周五"

msgid "Sat"
msgstr "周六"

msgid "Sun"
msgstr "周日"

msgid "Running"
msgstr "运行中"

msgid "Not Running"
msgstr "未运行"

msgid "Status"
msgstr "状态"

msgid "Collecting data..."
msgstr "正在收集数据..."

msgid "Basic Settings"
msgstr "基本设置"

msgid "Configure internet access time control for network devices"
msgstr "配置网络设备的上网时间控制"

msgid "Process Turbo ACC"
msgstr "处理 Turbo ACC"

msgid "Processing..."
msgstr "处理中..."

msgid "Turbo ACC Result:"
msgstr "Turbo ACC 结果："

msgid "Error:"
msgstr "错误："

msgid "Failed to process Turbo ACC"
msgstr "处理 Turbo ACC 失败"
EOF

# 创建翻译文件 - zh-cn (简体中文别名)
cat << 'EOF' > ./package/luci-app-timecontrol/po/zh-cn/timecontrol.po
msgid ""
msgstr "Content-Type: text/plain; charset=UTF-8\n"

msgid "Internet Time Control"
msgstr "上网时间控制"

msgid "Warning: Turbo ACC/offload detected, may cause iptables rules of this plugin to fail"
msgstr "警告：检测到启用了类似 Turbo ACC (flow offload)的功能，这会导致本插件的 iptables 规则失效。"

msgid "Enable Time Control"
msgstr "启用时间控制"

msgid "Hostname Scan Interval"
msgstr "主机名扫描间隔"

msgid "Scan interval in minutes (0 to disable automatic scanning)"
msgstr "扫描间隔分钟数（0表示禁用自动扫描）"

msgid "Scan Hostnames Now"
msgstr "立即扫描主机名"

msgid "Scan Now"
msgstr "立即扫描"

msgid "Scanning..."
msgstr "正在扫描..."

msgid "Scan failed"
msgstr "扫描失败"

msgid "Client Rules"
msgstr "客户端规则"

msgid "Configure time-based internet access rules for clients"
msgstr "为客户端配置基于时间的上网控制规则"

msgid "Enable"
msgstr "启用"

msgid "MAC Address"
msgstr "MAC地址"

msgid "Hostname"
msgstr "主机名"

msgid "Block Start Time"
msgstr "禁止上网开始时间"

msgid "Block End Time"
msgstr "禁止上网结束时间"

msgid "Mon"
msgstr "周一"

msgid "Tue"
msgstr "周二"

msgid "Wed"
msgstr "周三"

msgid "Thu"
msgstr "周四"

msgid "Fri"
msgstr "周五"

msgid "Sat"
msgstr "周六"

msgid "Sun"
msgstr "周日"

msgid "Running"
msgstr "运行中"

msgid "Not Running"
msgstr "未运行"

msgid "Status"
msgstr "状态"

msgid "Collecting data..."
msgstr "正在收集数据..."

msgid "Basic Settings"
msgstr "基本设置"

msgid "Configure internet access time control for network devices"
msgstr "配置网络设备的上网时间控制"

msgid "Process Turbo ACC"
msgstr "处理 Turbo ACC"

msgid "Processing..."
msgstr "处理中..."

msgid "Turbo ACC Result:"
msgstr "Turbo ACC 结果："

msgid "Error:"
msgstr "错误："

msgid "Failed to process Turbo ACC"
msgstr "处理 Turbo ACC 失败"
EOF

echo "Creating Makefile..."

# 创建Makefile
cat << 'EOF' > ./package/luci-app-timecontrol/Makefile
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-timecontrol
PKG_VERSION:=1.4
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for Internet Time Control
LUCI_DEPENDS:=+luci-compat
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
EOF

echo "Setting file permissions..."
chmod +x ./package/luci-app-timecontrol/root/etc/init.d/timecontrol
chmod +x ./package/luci-app-timecontrol/root/etc/uci-defaults/luci-app-timecontrol

echo ""
echo "=================================="
echo "完整版 Time Control Plugin v010 已创建!"
echo "=================================="
echo ""
echo "★★★ 主要内容 ★★★"
echo "1. 添加默认UCI配置文件 /etc/config/timecontrol"
echo "2. 统一配置类型为 'basic' (section名为'config')"
echo "3. 修复字段名: enable -> enabled"
echo "4. 简化按钮显示逻辑，使用独立的 SimpleSection"
echo "5. 修复 uci-defaults 初始化脚本"
echo "6. 修复 init.d 中的 uci 读取逻辑"
echo ""
echo "编译安装："
echo "1. make package/luci-app-timecontrol/clean"
echo "2. make package/luci-app-timecontrol/compile"
echo "3. opkg remove luci-app-timecontrol luci-i18n-timecontrol-zh-cn"
echo "4. opkg install bin/packages/*/luci/luci-app-timecontrol_*.ipk"
echo "5. opkg install bin/packages/*/luci/luci-i18n-timecontrol-zh-cn_*.ipk"
echo "6. rm -rf /tmp/luci-* && /etc/init.d/uhttpd restart"
echo ""
echo "测试方法："
echo "命令行测试: /etc/init.d/timecontrol scan showlogs"
echo "Web界面测试: 点击'立即扫描'按钮查看详细日志"
echo ""
echo "配置文件结构 (/etc/config/timecontrol):"
echo "config basic 'config'"
echo "    option enabled '0'"
echo "    option scan_interval '10'"
echo ""
echo "config macbind"
echo "    option enable '1'"
echo "    option macaddr '11:22:33:44:55:66'"
echo "    option hostname 'TIZEN'"
echo "    option timeon '22:00'"
echo "    option timeoff '06:00'"
echo "    option z1 '1'  # 周一"
echo "    option z7 '1'  # 周日"
echo ""
echo "=================================="
