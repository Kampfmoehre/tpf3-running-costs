-- Running Cost Breakdown for Transport Fever 3: the sampler (game script).
--
-- Every SAMPLE_MS of game time it classifies every vehicle (cost_classes.lua:
-- driving / waiting en route / at terminal / in depot) and accumulates the
-- time and the cost of that state into the vehicle's history (cost_history.lua,
-- a ring of buckets covering one default game year). The cost is split into
-- the vehicle's static rate (the sum of its parts' runningCosts, what a
-- healthy vehicle costs) and the maintenance-state surcharge on top
-- (getRunningCost - static), both charged at the state's factor, so the GUI
-- can show the surcharge as its own row.
--
-- update() is dispatched to one of the sim pool threads, each with its own
-- Lua state: nothing persistent lives in locals, everything goes through the
-- game-script state (saved with the game). State layout:
--   { version, tSample, tPerfLog, fails,
--     v = { [vehicle] = History },
--     summary = { [vehicle] = Summary + { line, rc, static, key, first } },
--     inc = { [vehicle or "L<line>"] = Ring with bucket.inc } (income records consumed
--           from income.script.lua's queue state), incSeen = { [recordId] = t },
--     stat = { [vehicle] = { r = static rate per year, t = last check } },
--     perf = { lastMs, maxMs } }
-- Vehicles come from transportVehicleSystem.getVehiclesWithState (four lists)
-- and getLine2VehicleMap; the TRANSPORT_VEHICLE component is only read when
-- the static rate is (re)checked, every STATIC_RECHECK_MS or when the running
-- cost drops below it (consist changed).
-- A version mismatch rebuilds the state from scratch.

function data()
	local VERSION = "0.2.0"
	local STATE_VERSION = 3       -- 2: histories carry `first`; 3: income rings `inc` (0.2.0)
	local MAX_FAILS = 10          -- consecutive failed steps before the state is rebuilt
	local SAMPLE_MS = 3000       -- game time between samples (8.5 ms per sample at 364 vehicles: state get 2.8, classify 2.8, set 2.9)
	local PERF_LOG_MS = 300000   -- game time between perf log lines
	local LOG_PREFIX = "[kampfmoehre_running_costs] "

	local classes = ug_require "kampfmoehre_running_costs_1::/running_costs/cost_classes.lua"
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
	local incomeSeen = false   -- log once per thread when the income queue delivered
	local INCOME_GS_NAME = "kampfmoehre_running_costs_1::/running_costs/income.gs"
	local incomeEntity = nil
	-- the queue of the income collector's state (a copy; tiny), or nil
	local function incomeQueue()
		if incomeEntity == nil then
			local ok, e = pcall(api.engine.system.gameScriptSystem.getEntityForGameScript, INCOME_GS_NAME)
			if ok and type(e) == "number" and e >= 0 then incomeEntity = e else return nil end
		end
		local ok, gs = pcall(api.engine.getComponent, incomeEntity, api.type.ComponentType.GAME_SCRIPT)
		if not ok or not gs then return nil end
		local okS, st = pcall(function() return gs.state end)
		if okS and type(st) == "table" and type(st.q) == "table" then return st.q end
		return nil
	end
	local STATE_NAMES = { "IN_DEPOT", "EN_ROUTE", "AT_TERMINAL", "GOING_TO_DEPOT" }

	-- static running cost per year of a consist: sum of the parts' metadata
	-- runningCosts (the rate of a healthy vehicle); cached per model id
	local modelStatic = {}
	local function staticPerYear(tv)
		local sum = 0
		local cfg = tv.transportVehicleConfig
		local parts = cfg and cfg.vehicles
		if type(parts) ~= "table" then return 0 end
		for __, part in ipairs(parts) do
			local id = part.part and part.part.modelId
			if id ~= nil then
				local v = modelStatic[id]
				if v == nil then
					v = 0
					local ok, model = pcall(api.res.modelRep.get, id)
					local maint = ok and model and model.metadata and model.metadata.maintenance
					if maint and type(maint.runningCosts) == "number" and maint.runningCosts > 0 then
						v = maint.runningCosts
					end
					modelStatic[id] = v
				end
				sum = sum + v
			end
		end
		return sum
	end

	-- consist static rate per vehicle, kept in the state: { r = per year, t = last check }
	local STATIC_RECHECK_MS = 60000
	local MAX_PENALTY_FACTOR = 1.3
	local function staticOf(s, v, now, rc)
		s.stat = s.stat or {}
		local e = s.stat[v]
		-- recheck early when rc dropped below the static rate (consist shrunk)
		-- or rose further above it than the condition penalty can explain
		-- (consist grew; the penalty tops out around +23 %)
		if e and now - (e.t or 0) < STATIC_RECHECK_MS and rc >= (e.r or 0) and rc <= (e.r or 0) * MAX_PENALTY_FACTOR then
			return e.r
		end
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		local r = tv and staticPerYear(tv) or 0
		s.stat[v] = { r = r, t = now }
		return r
	end

	local function vehicleStateEnum()
		return api.type["enum"] and api.type["enum"].TransportVehicleState
	end

	local function sample(s, now, dtMs)
		local yearMs = api.util.getDefaultYearDuration()
		local tvs = api.engine.system.transportVehicleSystem
		local enum = vehicleStateEnum()
		-- vehicles per state: four list calls instead of one component copy per vehicle
		local stateOf = {}
		if not enum then return nil end
		for __, name in ipairs(STATE_NAMES) do
			if enum[name] == nil then return nil end
			local ok, list = pcall(tvs.getVehiclesWithState, enum[name])
			if not ok or type(list) ~= "table" then return nil end   -- incomplete list: skip, keep histories
			for __, v in ipairs(list) do stateOf[v] = name end
		end
		local lineOf = {}
		local okM, map = pcall(tvs.getLine2VehicleMap)
		if okM and type(map) == "table" then
			for line, list in pairs(map) do
				for __, v in ipairs(list) do lineOf[v] = line end
			end
		end
		local count = 0
		for v, name in pairs(stateOf) do
			count = count + 1
			local speed = 0
			if name == "EN_ROUTE" or name == "GOING_TO_DEPOT" then
				speed = api.engine.util.vehicle.getSpeed(v) or 0
			end
			local key = classes.classify(name, speed)
			local rc = api.engine.util.vehicle.getRunningCost(v) or 0
			local static = staticOf(s, v, now, rc)
			if static <= 0 then static = rc end   -- unknown parts: no surcharge, cost at rc
			local h = s.v[v]
			if h == nil then
				h = history.new(now)
				s.v[v] = h
			end
			history.add(h, now, dtMs, key, static, math.max(0, rc - static), classes.factor(key), yearMs)
			local w = history.window(h, now, yearMs, classes.factor, yearMs)
			w.line = lineOf[v] or -1
			w.first = h.first   -- the income table (0.2.0) shares this window
			w.rc = rc
			w.static = static
			w.key = key
			s.summary[v] = w
		end
		for v in pairs(s.v) do
			if not stateOf[v] then
				s.v[v] = nil
				s.summary[v] = nil
				if s.stat then s.stat[v] = nil end
				if s.inc then s.inc[v] = nil end
			end
		end
		-- line-level income rings of lines that no longer exist (every ~60 s)
		if s.inc and (s.incSweep or 0) + 60000 <= now then
			s.incSweep = now
			for k in pairs(s.inc) do
				if type(k) == "string" then
					local line = tonumber(k:match("^L(%d+)$"))
					local okE, exists = line and pcall(api.engine.entityExists, line)
					if not line or (okE and not exists) then s.inc[k] = nil end
				end
			end
		end
		return count
	end

	local function step(state)
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		local now = gt and gt.gameTime
		if type(now) ~= "number" then return end
		local clock = api.type.Clock.new()
		local s = state:get()
		local tGet = clock:getTime() / 1000
		if type(s) ~= "table" or s.version ~= STATE_VERSION or type(s.tSample) ~= "number" or s.tSample > now
			or type(s.v) ~= "table" or type(s.summary) ~= "table" then
			s = { version = STATE_VERSION, tSample = now, tPerfLog = now, fails = 0,
				v = {}, summary = {}, inc = {}, perf = { lastMs = 0, maxMs = 0 } }
			state:set(s)
			log("v" .. VERSION .. " sampler started (fresh state) at gameTime=" .. now)
			return
		end
		if now - s.tSample < SAMPLE_MS then return end
		-- after a long pause one sample must not fill more than one bucket
		local dtMs = math.min(now - s.tSample, history.BUCKET_MS)
		s.tSample = now
		local count = sample(s, now, dtMs)
		if count == nil then return end   -- vehicle lists unavailable this tick: nothing written
		-- income records queued by income.script.lua (its own, tiny state)
		s.inc = s.inc or {}
		s.incSeen = s.incSeen or {}
		local queue = incomeQueue()
		if queue then
			local moved = history.queueConsume(queue, s.inc, s.incSeen, now)
			if moved > 0 then
				s.incItems = (s.incItems or 0) + moved
				if not incomeSeen then
					incomeSeen = true
					log("income queue read from income.script.lua: " .. moved .. " records consumed")
				end
			end
		end
		s.fails = 0
		local tSample = clock:getTime() / 1000
		state:set(s)
		local ms = clock:getTime() / 1000
		s.perf = s.perf or { lastMs = 0, maxMs = 0 }
		s.perf.lastMs = ms
		if ms > (s.perf.maxMs or 0) then s.perf.maxMs = ms end
		if now - (s.tPerfLog or 0) >= PERF_LOG_MS then
			s.tPerfLog = now
			state:set(s)
			log(string.format("perf: last sample %.2f ms (state get %.2f, classify %.2f, state set %.2f), max of logged samples %.2f ms, %d vehicles, %d income records consumed since the last line",
				ms, tGet, tSample - tGet, ms - tSample, s.perf.maxMs, count, s.incItems or 0))
			s.incItems = 0
		end
	end

	-- a step that keeps failing on a state of the current version (e.g. a
	-- damaged save) is given up after MAX_FAILS: the state is rebuilt
	local function noteFailure(state)
		pcall(function()
			local s = state:get()
			if type(s) ~= "table" then return end
			s.fails = (s.fails or 0) + 1
			if s.fails >= MAX_FAILS then
				log("resetting the state after " .. s.fails .. " failed steps in a row")
				state:set({ version = -1 })
			else
				state:set(s)
			end
		end)
	end

	local function update(userParams, state, dt)
		if dt == 0 then return end
		local ok, err = pcall(step, state)
		if not ok then
			errorCount = errorCount + 1
			if errorCount <= 10 then log("error: " .. tostring(err)) end
			noteFailure(state)
		end
	end

	return {
		update = update,
	}
end
