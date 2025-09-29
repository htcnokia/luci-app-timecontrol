local sys = require "luci.sys"
local m, s, o

m = Map("timecontrol", translate("Internet Time Control"),
	translate("Configure internet access time control for network devices"))

-- Basic Settings Section
s = m:section(TypedSection, "basic", translate("Basic Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enable", translate("Enable Time Control"))
o.rmempty = false
o.default = "0"

o = s:option(Value, "scan_interval", translate("Hostname Scan Interval"), 
	translate("Scan interval in minutes (0 to disable automatic scanning)"))
o.datatype = "uinteger"
o.default = "10"
o.rmempty = false

o = s:option(Button, "scan_now", translate("Scan Hostnames Now"))
o.inputtitle = translate("Scan Now")
o.inputstyle = "apply"
-- 添加JavaScript来处理扫描结果显示
o.template = "timecontrol/scan_button"

-- Client Settings Section
s = m:section(TypedSection, "macbind", translate("Client Rules"),
	translate("Configure time-based internet access rules for clients"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enable", translate("Enable"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "macaddr", translate("MAC Address"))
o.rmempty = true
sys.net.mac_hints(function(mac, name) 
	o:value(mac, "%s (%s)" % {mac, name}) 
end)

o = s:option(Value, "hostname", translate("Hostname"))
o.rmempty = true
o.placeholder = "e.g., TIZEN, MyPhone"

o = s:option(Value, "timeon", translate("Block Start Time"))
o.default = "22:00"
o.rmempty = false

o = s:option(Value, "timeoff", translate("Block End Time"))  
o.default = "06:00"
o.rmempty = false

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

return m
