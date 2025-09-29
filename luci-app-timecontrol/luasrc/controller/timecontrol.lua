module("luci.controller.timecontrol", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/timecontrol") then 
		return 
	end
	
	entry({"admin", "services", "timecontrol"}, 
		cbi("timecontrol"), 
		_("Internet Time Control"), 60).acl_depends = { "luci-app-timecontrol" }
		
	entry({"admin", "services", "timecontrol", "status"}, 
		call("status")).leaf = true
		
	entry({"admin", "services", "timecontrol", "scan"}, 
		call("scan_now")).leaf = true
end

function status()
	local e = {}
	e.status = (luci.sys.call("iptables -L FORWARD 2>/dev/null | grep -q TIMECONTROL") == 0)
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function scan_now()
	local sys = require "luci.sys"
	local util = require "luci.util"
	
	-- 执行扫描并获取输出
	local output = sys.exec("/etc/init.d/timecontrol scan showlogs 2>&1")
	
	local e = {}
	e.output = output
	e.success = (output:match("updated") ~= nil) or (output:match("No updates needed") ~= nil)
	
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
