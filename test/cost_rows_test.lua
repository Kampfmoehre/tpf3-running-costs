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

local T = M.build({ full }, C)
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

local T2 = M.build({ full, young }, C)
check("mixed coverage", T2.coverageMs == Y and T2.lessData == 1)
near("mixed sum", T2.sum, 123600, 1e-6)
near("mixed share of driving", T2.rows[1].share, 1060 / 1360, 1e-9)

-- "less data" only beyond the tolerance (two sampler intervals), not for the
-- 3 s a vehicle can lag behind another between two reads
local a = { cov = Y, t = { driving = 10 }, c = { driving = 10 }, s = 0, total = 10 }
local b5 = { cov = Y - 5000, t = { driving = 10 }, c = { driving = 10 }, s = 0, total = 10 }
local b7 = { cov = Y - 7000, t = { driving = 10 }, c = { driving = 10 }, s = 0, total = 10 }
check("tolerance covers two sampler intervals", M.COVERAGE_TOLERANCE_MS == 6000)
check("5 s behind is not less data", M.build({ a, b5 }, C).lessData == 0)
check("7 s behind is less data", M.build({ a, b7 }, C).lessData == 1)

local T3 = M.build({ young }, C)
check("header with partial coverage", M.minutes(T3.coverageMs) == 2 and T3.lessData == 0)
check("no surcharge row at 0", T3.surcharge == nil)

check("no summaries -> empty", M.build({}, C).empty == true and #M.build({}, C).rows == 0)
check("nil summaries -> empty", M.build(nil, C).empty == true)
check("zero coverage -> empty", M.build({ { cov = 0, t = {}, c = {}, s = 0, total = 0 } }, C).empty == true)
check("unknown keys ignored", #M.build({ { cov = Y, t = { x = 5 }, c = { x = 5 }, s = 0, total = 5 } }, C).rows == 0)
check("surcharge pct nil without class costs", M.build({ { cov = Y, t = {}, c = {}, s = 10, total = 10 } }, C).surcharge.pct == nil)

local L = M.live(618211, 537575, "terminal", C)
near("live per minute", L.perMin, 618211 * 60 / 1461 * 0.4, 1e-3)
check("live surcharge", L.surchargePct == 15 and L.colour == "ok" and L.factor == 0.4, tostring(L.surchargePct))
check("live healthy", M.live(1000, 1000, "driving", C).surchargePct == 0)
check("live static 0 -> 0 %", M.live(1000, 0, "driving", C).surchargePct == 0)
check("live waiting is warn", M.live(1000, 1000, "waiting", C).colour == "warn")

check("less-data key: singular for 1, plural otherwise", M.lessDataKey(1) == "running_costs_less_data_one" and M.lessDataKey(2) == "running_costs_less_data" and M.lessDataKey(0) == "running_costs_less_data")
check("minutes rounds, at least 1 once there is data", M.minutes(1461000) == 24 and M.minutes(90000) == 2 and M.minutes(29000) == 1 and M.minutes(0) == 0 and M.minutes(nil) == 0)

-- income rows (0.2.0)
local e1 = { [7] = { n = 2, base = 800, ok = 1, q = 2 }, [9] = { n = 1, base = 100, ok = 0, q = 0 } }
local e2 = { [7] = { n = 1, base = 200, ok = 1, q = 1 } }
local Em = M.mergeIncome({ e1, e2 })
check("merge sums per key", Em[7].n == 3 and Em[7].base == 1000 and Em[7].ok == 2 and Em[7].q == 3 and Em[9].n == 1)
near("scale factor", M.scaleFactor(Em, 550), 0.5, 1e-9)
check("no factor without bookings", M.scaleFactor(Em, nil) == nil and M.scaleFactor(Em, 0) == nil and M.scaleFactor(Em, -5) == nil)
check("no factor without base", M.scaleFactor({ [7] = { n = 1, base = 0, ok = 0, q = 0 } }, 100) == nil)
local names = { [7] = "Grain" }
local T = M.buildIncome(Em, 0.5, function(k) return names[k] end)
check("rows sorted by income, named, unknown key as id", #T.rows == 2 and T.rows[1].key == 7 and T.rows[1].name == "Grain" and T.rows[2].name == "9")
near("scaled income", T.rows[1].income, 500, 1e-9); near("per item", T.rows[1].perItem, 500 / 3, 1e-9)
near("on-time share", T.rows[1].onTimeShare, 2 / 3, 1e-9)
check("passengers: no on-time share", T.rows[2].onTimeShare == nil)
check("sum", T.sum.n == 4 and math.abs(T.sum.income - 550) < 1e-9 and T.scaled == true and T.empty == false)
local R = M.buildIncome(Em, nil, function() return nil end)
check("raw mode", R.scaled == false and math.abs(R.rows[1].income - 1000) < 1e-9)
check("zero base: no per item, no crash", M.buildIncome({ [7] = { n = 2, base = 0, ok = 0, q = 0 } }, nil, function() end).rows[1].perItem == nil)
check("fractional items below 0.5 are dropped", M.buildIncome({ [7] = { n = 0.4, base = 10, ok = 0, q = 0 } }, nil, function() end).empty == true)
check("empty entries", M.buildIncome({}, nil, function() end).empty == true and M.buildIncome(nil, nil, function() end).empty == true)
check("empty but account readable counts as scaled", M.buildIncome({}, nil, function() end, true).scaled == true and M.buildIncome({}, nil, function() end, false).scaled == false)
local costT = { sum = 300, empty = false }
near("result = income - costs when scaled", M.result(T, costT), 250, 1e-9)
check("no result in raw mode", M.result(R, costT) == nil)
near("no income but costs: result is minus the costs", M.result({ rows = {}, sum = { n = 0, base = 0, income = 0 }, scaled = true, empty = true }, costT), -300, 1e-9)
check("nothing at all: no result", M.result({ rows = {}, sum = { n = 0, base = 0, income = 0 }, scaled = false, empty = true }, { sum = 0, empty = true }) == nil)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
