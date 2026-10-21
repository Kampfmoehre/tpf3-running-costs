-- Cost classes of Running Cost Breakdown: the states the game charges a
-- vehicle's running costs in, with the factor it applies (measured
-- 2026-10-20, see docs/superpowers/specs/2026-10-20-running-cost-breakdown-design.md):
-- driving and waiting en route 100 %, at a terminal 40 %, in a depot 5 %.
--
-- The list is the single source for the sampler (what to accumulate) and the
-- GUI (which rows to show, in which order, in which colour). Later versions
-- add entries (speed buckets, balancing-mod corrections) here only.
--
-- No game API, unit-tested with plain luajit (test/cost_classes_test.lua).
local M = {}

-- colour: "default" (plain text/bar), "ok" (green, reduced rate),
-- "warn" (orange, full rate without progress), "off" (grey, parked)
-- labelKey: table row; shortKey: the vehicle window's live line (one line)
M.CLASSES = {
	{ key = "driving", factor = 1.0, labelKey = "running_costs_class_driving", shortKey = "running_costs_short_driving", colour = "default" },
	{ key = "waiting", factor = 1.0, labelKey = "running_costs_class_waiting", shortKey = "running_costs_short_waiting", colour = "warn" },
	{ key = "terminal", factor = 0.4, labelKey = "running_costs_class_terminal", shortKey = "running_costs_short_terminal", colour = "ok" },
	{ key = "depot", factor = 0.05, labelKey = "running_costs_class_depot", shortKey = "running_costs_short_depot", colour = "off" },
}

-- Not a class: the maintenance-state surcharge is accumulated over all
-- states and shown as its own row.
M.SURCHARGE_KEY = "surcharge"

M.byKey = {}
for __, c in ipairs(M.CLASSES) do M.byKey[c.key] = c end

M.STANDING_SPEED = 0.5   -- m/s; below this an EN_ROUTE vehicle counts as waiting

-- stateName: "IN_DEPOT" | "EN_ROUTE" | "AT_TERMINAL" | "GOING_TO_DEPOT"
-- (the TransportVehicleState enum name), speedMps may be nil -> class key
function M.classify(stateName, speedMps, standingSpeed)
	if stateName == "IN_DEPOT" then return "depot" end
	if stateName == "AT_TERMINAL" then return "terminal" end
	if (stateName == "EN_ROUTE" or stateName == "GOING_TO_DEPOT")
		and (speedMps or 0) < (standingSpeed or M.STANDING_SPEED) then
		return "waiting"
	end
	return "driving"   -- moving, or a state this version does not know (charged in full)
end

function M.factor(key)
	local c = M.byKey[key]
	return c and c.factor or 1.0
end

return M
