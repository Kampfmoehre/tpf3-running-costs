-- run: luajit test/cost_rows_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/?.lua;"
	.. "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "cost_rows"
local C = require "cost_classes"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end
local function near(name, got, want, tol)
	check(name, type(got) == "number" and math.abs(got - want) <= tol, string.format("got %s, want %s", tostring(got), tostring(want)))
end

local Y = 1461000
local full = { cov = Y, t = { driving = 1000, terminal = 300, depot = 0 }, c = { driving = 100000, terminal = 12000, depot = 0 }, s = 5600, total = 117600 }
local young = { cov = 120000, t = { driving = 60 }, c = { driving = 6000 }, s = 0, total = 6000 }

local T = M.build({ full }, C, Y)
check("two visible rows (depot hidden at 0 s)", #T.rows == 2 and T.rows[1].key == "driving" and T.rows[2].key == "terminal", tostring(#T.rows))
near("share of terminal", T.rows[2].share, 300 / 1300, 1e-9)
near("seconds of terminal", T.rows[2].seconds, 300, 1e-9)
near("amount of terminal", T.rows[2].amount, 12000, 1e-9)
check("row carries label key, factor and colour", T.rows[2].labelKey == "running_costs_class_terminal" and T.rows[2].factor == 0.4 and T.rows[2].colour == "ok")
near("sum includes surcharge", T.sum, 117600, 1e-6)
near("surcharge amount", T.surcharge.amount, 5600, 1e-6)
near("surcharge pct of class costs", T.surcharge.pct, 5.0, 1e-6)
check("header with full coverage", T.coverageMs == Y and T.lessData == 0 and M.minutes(T.coverageMs) == 24)
check("not empty", T.empty == false)

local T2 = M.build({ full, young }, C, Y)
check("mixed coverage", T2.coverageMs == Y and T2.lessData == 1)
near("mixed sum", T2.sum, 123600, 1e-6)
near("mixed share of driving", T2.rows[1].share, 1060 / 1360, 1e-9)

local T3 = M.build({ young }, C, Y)
check("header with partial coverage", M.minutes(T3.coverageMs) == 2 and T3.lessData == 0)
check("no surcharge row at 0", T3.surcharge == nil)

check("no summaries -> empty", M.build({}, C, Y).empty == true and #M.build({}, C, Y).rows == 0)
check("nil summaries -> empty", M.build(nil, C, Y).empty == true)
check("zero coverage -> empty", M.build({ { cov = 0, t = {}, c = {}, s = 0, total = 0 } }, C, Y).empty == true)
check("unknown keys ignored", #M.build({ { cov = Y, t = { x = 5 }, c = { x = 5 }, s = 0, total = 5 } }, C, Y).rows == 0)
check("surcharge pct nil without class costs", M.build({ { cov = Y, t = {}, c = {}, s = 10, total = 10 } }, C, Y).surcharge.pct == nil)

local L = M.live(618211, 537575, "terminal", C)
near("live per minute", L.perMin, 618211 * 60 / 1461 * 0.4, 1e-3)
check("live surcharge", L.surchargePct == 15 and L.colour == "ok" and L.factor == 0.4, tostring(L.surchargePct))
check("live healthy", M.live(1000, 1000, "driving", C).surchargePct == 0)
check("live static 0 -> 0 %", M.live(1000, 0, "driving", C).surchargePct == 0)
check("live waiting is warn", M.live(1000, 1000, "waiting", C).colour == "warn")

check("minutes rounds, at least 1 once there is data", M.minutes(1461000) == 24 and M.minutes(90000) == 2 and M.minutes(29000) == 1 and M.minutes(0) == 0 and M.minutes(nil) == 0)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
