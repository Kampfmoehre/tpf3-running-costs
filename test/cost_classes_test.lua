-- run: luajit test/cost_classes_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "cost_classes"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end

check("order", M.CLASSES[1].key == "driving" and M.CLASSES[2].key == "waiting" and M.CLASSES[3].key == "terminal" and M.CLASSES[4].key == "depot")
check("exactly four classes", #M.CLASSES == 4)
check("factors", M.factor("terminal") == 0.4 and M.factor("depot") == 0.05 and M.factor("driving") == 1 and M.factor("nonsense") == 1)
check("label keys", M.CLASSES[1].labelKey == "running_costs_class_driving" and M.CLASSES[3].labelKey == "running_costs_class_terminal")
check("colours", M.byKey.driving.colour == "default" and M.byKey.waiting.colour == "warn" and M.byKey.terminal.colour == "ok" and M.byKey.depot.colour == "off")
check("surcharge key", M.SURCHARGE_KEY == "surcharge")
check("short label keys for the live line", M.byKey.driving.shortKey == "running_costs_short_driving" and M.byKey.terminal.shortKey == "running_costs_short_terminal" and M.byKey.depot.shortKey == "running_costs_short_depot" and M.byKey.waiting.shortKey == "running_costs_short_waiting")
check("depot", M.classify("IN_DEPOT", 0) == "depot")
check("terminal", M.classify("AT_TERMINAL", 0) == "terminal")
check("en route moving", M.classify("EN_ROUTE", 8.3) == "driving")
check("en route standing", M.classify("EN_ROUTE", 0.1) == "waiting")
check("going to depot standing", M.classify("GOING_TO_DEPOT", 0) == "waiting")
check("going to depot moving", M.classify("GOING_TO_DEPOT", 5) == "driving")
check("standing threshold is a parameter", M.classify("EN_ROUTE", 0.8, 1.0) == "waiting")
check("unknown state is driving", M.classify("state_7", 0) == "driving")
check("nil speed is standing", M.classify("EN_ROUTE", nil) == "waiting")

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
