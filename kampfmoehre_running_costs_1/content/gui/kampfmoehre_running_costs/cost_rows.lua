-- Table rows and the live line of Running Cost Breakdown, built from the
-- sampler's per-vehicle summaries (running_costs.script.lua in
-- content/running_costs/: { cov, t = {key = s}, c = {key = cost}, s, total }).
--
-- A line passes the summaries of all its vehicles, each with its own
-- coverage; the header names the longest one and how many vehicles have
-- less. Rows follow the class list (cost_classes.lua) and only appear for
-- classes with time in the window; the surcharge is a row of its own.
--
-- No game API, unit-tested with plain luajit (test/cost_rows_test.lua).
local M = {}

M.YEAR_S = 1461              -- default game year in seconds of game time
M.COVERAGE_TOLERANCE_MS = 6000   -- two sampler intervals: vehicles are read one by one

local function round(x)
	return math.floor(x + 0.5)
end

-- summaries: {Summary}, classes: the cost_classes module ->
-- { rows = { { key, labelKey, factor, colour, seconds, share, amount } },
--   surcharge = { amount, pct } | nil, sum, coverageMs, lessData, empty }
function M.build(summaries, classes)
	local out = { rows = {}, surcharge = nil, sum = 0, coverageMs = 0, lessData = 0, empty = true }
	if type(summaries) ~= "table" then return out end
	local t, c, s = {}, {}, 0
	local covs = {}
	for __, w in ipairs(summaries) do
		if type(w) == "table" and (w.cov or 0) > 0 then
			covs[#covs + 1] = w.cov
			if w.cov > out.coverageMs then out.coverageMs = w.cov end
			for k, v in pairs(w.t or {}) do t[k] = (t[k] or 0) + v end
			for k, v in pairs(w.c or {}) do
				c[k] = (c[k] or 0) + v
				out.sum = out.sum + v
			end
			s = s + (w.s or 0)
		end
	end
	if #covs == 0 then return out end
	out.empty = false
	out.sum = out.sum + s
	for __, cov in ipairs(covs) do
		if cov < out.coverageMs - M.COVERAGE_TOLERANCE_MS then out.lessData = out.lessData + 1 end
	end
	local totalSeconds, classCost = 0, 0
	for __, cl in ipairs(classes.CLASSES) do
		totalSeconds = totalSeconds + (t[cl.key] or 0)
		classCost = classCost + (c[cl.key] or 0)
	end
	for __, cl in ipairs(classes.CLASSES) do
		local sec = t[cl.key] or 0
		if sec > 0 then
			out.rows[#out.rows + 1] = {
				key = cl.key,
				labelKey = cl.labelKey,
				factor = cl.factor,
				colour = cl.colour,
				seconds = sec,
				share = totalSeconds > 0 and sec / totalSeconds or 0,
				amount = c[cl.key] or 0,
			}
		end
	end
	if s > 0 then
		out.surcharge = { amount = s, pct = classCost > 0 and 100 * s / classCost or nil }
	end
	return out
end

-- rcPerYear = getRunningCost (incl. surcharge), staticPerYear = the parts'
-- runningCosts sum, key = current class ->
-- { perMin, factor, surchargePct (integer, >= 0), colour }
function M.live(rcPerYear, staticPerYear, key, classes)
	local factor = classes.factor(key)
	local pct = 0
	if (staticPerYear or 0) > 0 then
		pct = math.max(0, round(100 * ((rcPerYear or 0) - staticPerYear) / staticPerYear))
	end
	local cl = classes.byKey[key]
	return {
		perMin = (rcPerYear or 0) * 60 / M.YEAR_S * factor,
		factor = factor,
		surchargePct = pct,
		colour = cl and cl.colour or "default",
	}
end

-- Income (0.2.0) ----------------------------------------------------------------

-- per-vehicle income windows ({ [key] = { n, base, ok, q } }) -> one table
function M.mergeIncome(list)
	local out = {}
	for __, entries in ipairs(list or {}) do
		for k, e in pairs(entries or {}) do
			local o = out[k]
			if o == nil then
				o = { n = 0, base = 0, ok = 0, q = 0 }
				out[k] = o
			end
			o.n = o.n + (e.n or 0)
			o.base = o.base + (e.base or 0)
			o.ok = o.ok + (e.ok or 0)
			o.q = o.q + (e.q or 0)
		end
	end
	return out
end

local function sumBase(entries)
	local t = 0
	for __, e in pairs(entries or {}) do t = t + (e.base or 0) end
	return t
end

-- booked income of the account over the window / sum of the base values ->
-- the factor that turns base values into booked money, nil when either is
-- missing or not positive
function M.scaleFactor(entries, booked)
	if type(booked) ~= "number" or booked <= 0 then return nil end
	local base = sumBase(entries)
	if base <= 0 then return nil end
	return booked / base
end

-- entries -> { rows = { { key, name, n, base, income, perItem | nil, onTimeShare | nil } },
--   sum = { n, base, income }, scaled, empty }; nameOf(key) -> display name or nil;
-- bookedKnown: an account was readable (an empty table is then still "scaled")
function M.buildIncome(entries, factor, nameOf, bookedKnown)
	local out = { rows = {}, sum = { n = 0, base = 0, income = 0 }, scaled = factor ~= nil, empty = true }
	if bookedKnown == true and sumBase(entries) == 0 then out.scaled = true end
	for k, e in pairs(entries or {}) do
		local n = round(e.n or 0)
		if n > 0 then
			local income = (e.base or 0) * (factor or 1)
			local r = {
				key = k,
				name = (nameOf and nameOf(k)) or tostring(k),
				n = n,
				base = e.base or 0,
				income = income,
				perItem = (n >= 1 and income > 0) and income / n or nil,
				onTimeShare = ((e.q or 0) > 0) and (e.ok or 0) / e.q or nil,
			}
			out.rows[#out.rows + 1] = r
			out.sum.n = out.sum.n + n
			out.sum.base = out.sum.base + r.base
			out.sum.income = out.sum.income + income
		end
	end
	table.sort(out.rows, function(a, b)
		if a.income ~= b.income then return a.income > b.income end
		return tostring(a.key) < tostring(b.key)
	end)
	out.empty = #out.rows == 0
	return out
end

-- income minus running costs of the window, nil when the income is not scaled
-- (base prices are no result) or nothing at all is known
function M.result(incomeTable, costTable)
	if not incomeTable or not incomeTable.scaled then return nil end
	if incomeTable.empty and (not costTable or costTable.empty) then return nil end
	return (incomeTable.sum and incomeTable.sum.income or 0) - ((costTable and costTable.sum) or 0)
end

-- strings.json key for the "n vehicles with less data" note: the game has no
-- plural helper, so singular and plural are two keys
function M.lessDataKey(n)
	if n == 1 then return "running_costs_less_data_one" end
	return "running_costs_less_data"
end

-- coverage in ms -> whole minutes of game time for the header; at least 1
-- once there is any data (a header "last 0 min" reads as broken)
function M.minutes(ms)
	ms = ms or 0
	if ms <= 0 then return 0 end
	return math.max(1, round(ms / 60000))
end

return M
