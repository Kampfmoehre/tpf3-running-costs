-- Running Cost Breakdown for Transport Fever 3: the income collector (game
-- script, engine side, event-only).
--
-- The game raises OnCalcTicketPrice for every paid item, batched: id
-- "TransportVehicleSystem" for cargo, id "SimEntityAtVehicleSystem" for
-- passengers. Measured shape of an event (build 40422, differs from the
-- tealdef): { vehicleEntity, lineEntity, simEntity, stockListEntity,
-- basePrice, fromPos, toPos }, where basePrice is already the whole base
-- income of the item (80 items × 10 862 = the 868 880 the finance window
-- showed) and vehicleEntity repeats simEntity (a game bug). The vehicle
-- therefore comes from the item's SIM_ENTITY_AT_VEHICLE component (what the
-- game's cargo flow HUD reads on unloaded items), the cargo type from
-- SIM_CARGO; passengers are the game's own passenger cargo type. Items whose
-- vehicle cannot be found are kept under the line ("L<line>") so the line
-- table still sees them. Per key, cargo type and time bucket this script
-- counts items, base income (before the company-level factor) and on-time
-- items, in the same bucket ring as the costs (cost_history.lua). The handler
-- NEVER returns a value: a returned table would change the prices.
--
-- Every pool thread has its own Lua state, so items of one delivery arrive
-- on many threads and no thread can see another's locals. The collector
-- therefore aggregates each batch and appends it as a few compact records to
-- its own state, which is kept tiny: records older than QUEUE_MS are trimmed
-- on every write, and the cost sampler (running_costs.script.lua) consumes
-- the new records into the rings of its own state every sample, deduplicated
-- by record id. A per-batch get/set of a tiny state costs a fraction of a
-- millisecond; writing the rings per batch was the expensive variant.
-- State: { version, q = { [id] = { rk, key, t, n, base, ok, q, at } }, batches, items, perf, tPerfLog }

function data()
	local VERSION = "0.2.0"
	local INCOME_STATE_VERSION = 3  -- 3: a queue of records, consumed by the cost sampler
	local QUEUE_MS = 8000         -- records stay this long (the sampler reads every 3 s; ~0.3 ms per batch at 15 s)
	local PERF_LOG_MS = 300000
	local EVENT = "OnCalcTicketPrice"
	local LIFECYCLE = { initNewGame = true, initNewGameFromMap = true, initMission = true, handleLegacy = true }
	local DEBUG_LIFECYCLE = false -- log every lifecycle event name once per thread
	local DEBUG_BATCHES = 0       -- log the first N batches per thread in detail (0 = off)
	local debuggedBatches = 0
	local LOG_PREFIX = "[kampfmoehre_running_costs] "

	local history = ug_require "kampfmoehre_running_costs_1::/running_costs/cost_history.lua"

	local gameLog = log   -- the game's global log table, before the local below shadows it
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then
			gameLog.message(LOG_PREFIX .. tostring(text))
		else
			print(LOG_PREFIX .. tostring(text))
		end
	end

	local errorCount = 0
	local seenLifecycle = {}
	local passengerIdCache = nil
	local buffer = history.newBuffer()
	-- id prefix unique per Lua state (threads cannot see each other's counters)
	local tag = nil


	local function passengerId()
		if passengerIdCache == nil then
			local ok, id = pcall(api.res.cargoTypeRep.getPassengerCargoTypeId)
			passengerIdCache = (ok and type(id) == "number") and id or false
		end
		return passengerIdCache or nil
	end

	local function gameTime()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return gt and gt.gameTime or nil
	end

	local function ensureSubscribed(state)
		if not state:hasEventSubscriptions() then
			state:subscribeToEvent(EVENT)
			log("v" .. VERSION .. " income collector subscribed to " .. EVENT)
		end
	end

	-- the vehicle that delivered the item: SIM_ENTITY_AT_VEHICLE, else the
	-- event's vehicleEntity when it is not the item itself, else the cargo's
	-- last pickup point; nil when unknown
	local function vehicleOf(e)
		local okA, at = pcall(api.engine.getComponent, e.simEntity, api.type.ComponentType.SIM_ENTITY_AT_VEHICLE)
		if okA and at and type(at.vehicle) == "number" and at.vehicle >= 0 then return at.vehicle end
		if type(e.vehicleEntity) == "number" and e.vehicleEntity >= 0 and e.vehicleEntity ~= e.simEntity then
			local okT, tv = pcall(api.engine.getComponent, e.vehicleEntity, api.type.ComponentType.TRANSPORT_VEHICLE)
			if okT and tv then return e.vehicleEntity end
		end
		local okC, sc = pcall(api.engine.getComponent, e.simEntity, api.type.ComponentType.SIM_CARGO)
		local pts = okC and sc and sc.pickupPoints
		if type(pts) == "table" and #pts > 0 then
			local last = pts[#pts]
			if type(last) == "table" and type(last.vehicle) == "number" and last.vehicle >= 0 then return last.vehicle end
		end
		return nil
	end

	-- ring key: the vehicle, or "L<line>" when only the line is known
	local function ringKey(e)
		local v = vehicleOf(e)
		if v ~= nil then return v end
		if type(e.lineEntity) == "number" and e.lineEntity >= 0 then return "L" .. e.lineEntity end
		return nil
	end

	local function cargoKey(id, e)
		if id == "SimEntityAtVehicleSystem" then return passengerId() end
		local ok, sc = pcall(api.engine.getComponent, e.simEntity, api.type.ComponentType.SIM_CARGO)
		if ok and sc and type(sc.cargoType) == "number" then return sc.cargoType end
		return nil
	end

	local function freshState(now)
		return { version = INCOME_STATE_VERSION, q = {}, batches = 0, items = 0, tPerfLog = now or 0,
			perf = { ms = 0, n = 0, maxMs = 0 } }
	end

	local function handleBatch(state, id, param)
		if type(param) ~= "table" then return end
		local clock = api.type.Clock.new()
		local now = gameTime()
		if type(now) ~= "number" then return end
		if tag == nil then
			tag = string.format("%x%x", math.floor(now % 1000000), math.random(1, 1000000000))
		end
		local isPassengers = (id == "SimEntityAtVehicleSystem")
		local debugThis = debuggedBatches < DEBUG_BATCHES
		if debugThis then
			debuggedBatches = debuggedBatches + 1
			local e1 = param[1]
			log(string.format("debug batch: id=%s n=%d first=%s vehicle=%s sim=%s basePrice=%s",
				tostring(id), #param, type(e1), e1 and tostring(e1.vehicleEntity) or "-", e1 and tostring(e1.simEntity) or "-",
				e1 and tostring(e1.basePrice) or "-"))
		end
		local items = 0
		for __, e in ipairs(param) do
			if type(e) == "table" and type(e.simEntity) == "number" then
				local key = cargoKey(id, e)
				local rk = ringKey(e)
				if debugThis then log("debug item: cargo=" .. tostring(key) .. " ring=" .. tostring(rk)) end
				if key ~= nil and rk ~= nil then
					-- passengers have no delivery quality: their on-time cell stays "–"
					local ok = nil
					if not isPassengers then
						local okQ, q = pcall(api.engine.util.cargo.isGoodQuality, e.simEntity)
						if okQ and type(q) == "boolean" then ok = q end
					end
					history.bufferAdd(buffer, rk, key, now, tonumber(e.basePrice) or 0, ok)
					items = items + 1
				end
			end
		end
		if items == 0 then return end
		local s = state:get()
		if type(s) ~= "table" or s.version ~= INCOME_STATE_VERSION or type(s.q) ~= "table" then
			s = freshState(now)
			log("v" .. VERSION .. " income collector started (fresh state) at gameTime=" .. now)
		end
		history.queueAppend(s.q, buffer, tag, now)
		history.queueTrim(s.q, now, QUEUE_MS)
		s.items = (s.items or 0) + items
		s.batches = (s.batches or 0) + 1
		local ms = clock:getTime() / 1000
		s.perf = s.perf or { ms = 0, n = 0, maxMs = 0 }
		s.perf.ms = (s.perf.ms or 0) + ms
		s.perf.n = (s.perf.n or 0) + 1
		if ms > (s.perf.maxMs or 0) then s.perf.maxMs = ms end
		if now - (s.tPerfLog or 0) >= PERF_LOG_MS then
			local qn = 0
			for __ in pairs(s.q) do qn = qn + 1 end
			log(string.format("income perf over %.0f s of game time: %d batches / %d items, %.2f ms per batch (state get/set incl.), max %.2f ms, %d records queued",
				(now - (s.tPerfLog or 0)) / 1000, s.batches or 0, s.items or 0, s.perf.ms / math.max(1, s.perf.n), s.perf.maxMs, qn))
			s.perf = { ms = 0, n = 0, maxMs = 0 }
			s.batches, s.items, s.tPerfLog = 0, 0, now
		end
		state:set(s)
	end

	local function handleEvent(userParams, state, src, id, name, param)
		local ok, err = pcall(function()
			if id == "" and LIFECYCLE[name] then
				ensureSubscribed(state)
			elseif id == "" and DEBUG_LIFECYCLE and not seenLifecycle[name] then
				seenLifecycle[name] = true
				log("lifecycle event: " .. tostring(name))
			end
			if name == EVENT and (id == "TransportVehicleSystem" or id == "SimEntityAtVehicleSystem") then
				handleBatch(state, id, param)
			end
		end)
		if not ok then
			errorCount = errorCount + 1
			if errorCount <= 10 then log("income error: " .. tostring(err)) end
		end
		-- never return anything: a returned table would change the prices
	end

	return {
		handleEvent = handleEvent,
	}
end
