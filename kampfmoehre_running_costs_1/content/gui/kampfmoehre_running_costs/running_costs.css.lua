local ssu = require "::/gui/main/stylesheetutil.lua"

-- Running Cost Breakdown: the breakdown table (running_costs.script.lua
-- CostTable) with time-share bars like Top Speed's section table, and the
-- colour of the vehicle window's live line.
function data()
	local result = {}
	local a = ssu.makeAdder(result)

	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data

	a("R::KampfmoehreRunningCostsTable TextView", {
		padding = { 1, 6, 1, 6 },
	})
	a("R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-bar", {
		gravity = { -1, 0.5 },
		backgroundColor1 = colorDefault.BaseVeryLight,
		color = colorDefault.AccentLight,
		margin = { 2, 4, 2, 4 },
		minSize = { 90, -1 },
	})
	a("!font-small R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-bar", { size = { -1, 20 } })
	a("!font-medium R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-bar", { size = { -1, 24 } })
	a("!font-large R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-bar", { size = { -1, 28 } })
	-- reduced rate (terminal)
	a("R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-ok", {
		color = colorDefault.Ok,
	})
	-- full rate without progress (waiting en route)
	a("R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-warn", {
		color = colorDefault.Warning,
	})
	-- parked (depot)
	a("R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-off", {
		color = colorDefault.BaseLightMedium,
	})
	-- amounts right-aligned, whatever side the currency symbol is on
	a("R::KampfmoehreRunningCostsTable TextView!kampfmoehre-rc-money", {
		gravity = { 1, 0.5 },
	})
	-- counts and percentages right-aligned too (income table)
	a("R::KampfmoehreRunningCostsTable TextView!kampfmoehre-rc-num", {
		gravity = { 1, 0.5 },
	})
	-- cargo icon of the income table, sized like a text line
	a("R::KampfmoehreRunningCostsTable ImageView!kampfmoehre-rc-cargo", {
		gravity = { 0, 0.5 },
		margin = { 2, 4, 2, 4 },
	})
	a("!font-small R::KampfmoehreRunningCostsTable ImageView!kampfmoehre-rc-cargo", { size = { 20, 20 } })
	a("!font-medium R::KampfmoehreRunningCostsTable ImageView!kampfmoehre-rc-cargo", { size = { 24, 24 } })
	a("!font-large R::KampfmoehreRunningCostsTable ImageView!kampfmoehre-rc-cargo", { size = { 28, 28 } })
	a("R::KampfmoehreRunningCostsTable Component!kampfmoehre-rc-barcell", {
		gravity = { -1, -1 },
	})
	-- live line while waiting en route (also used outside the table)
	a("TextView!kampfmoehre-rc-warn", {
		color = colorDefault.Warning,
	})

	return result
end
