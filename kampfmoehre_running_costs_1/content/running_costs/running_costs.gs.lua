-- Game-script registration of Running Cost Breakdown's sampler (found by the
-- .gs.lua extension, fileName relative to this folder). update runs on the
-- engine side; the GUI reads the saved state through the GAME_SCRIPT component
-- of the entity api.engine.system.gameScriptSystem.getEntityForGameScript(
-- "kampfmoehre_running_costs_1::/running_costs/running_costs.gs").
function data()
	return {
		updateScript = {
			fileName = "running_costs.script@update",
		},
	}
end
