-- Game-script registration of Running Cost Breakdown's income collector
-- (found by the .gs.lua extension, fileName relative to this folder). It has
-- no update: it only listens to OnCalcTicketPrice and keeps its own, small
-- state, read by the GUI through getEntityForGameScript(
-- "kampfmoehre_running_costs_1::/running_costs/income.gs").
function data()
	return {
		handleEventScript = {
			fileName = "income.script@handleEvent",
		},
	}
end
