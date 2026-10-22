-- Running Cost Breakdown for Transport Fever 3: the GUI side.
--
-- The game charges a vehicle's running costs at different rates depending on
-- its state (measured 2026-10-20: driving and waiting en route 100 %, at a
-- terminal 40 %, in a depot 5 %) and adds a surcharge for poor condition, but
-- shows only one "Running Costs" bar. This script shows:
--  * in the vehicle window (VehiclePlugin, order 18) a live line "Costs now
--    X/min · <state> · condition +y %", expandable to a table of the last
--    default game year by state;
--  * in the line window the same table under the income graph of the
--    "Balance" card: content_card.ContentCard is wrapped and, for the card
--    with localKey "lineBalance", its permanent recipe is replaced by one that
--    renders the original graph plus our table (BalanceWithCosts).
-- The history comes from the game script in content/running_costs/
-- (running_costs.script.lua), read through the GAME_SCRIPT component of its
-- entity; the live line is computed here from the vehicle component.
-- Pure helpers: cost_classes.lua (classes, factors) and cost_rows.lua (rows,
-- live values), both unit-tested with luajit.

function data()
	local VERSION = "0.2.0"
	local SAMPLE_S = 2     -- seconds between reads of the sampler state / table refreshes
	local LOG_PREFIX = "[kampfmoehre_running_costs] "
	local GS_NAME = "kampfmoehre_running_costs_1::/running_costs/running_costs.gs"
	local CARD_KEY = "kampfmoehreRunningCosts"
	local DEFAULT_YEAR_MS = 1461000
	local BOOKING_LUMP_MS = 60000   -- the game books running costs every 60 s of game time

	local react = ug_require "::/gui/main/react.lua"
	local builtin = ug_require "::/gui/main/builtin.lua"
	local content_card = ug_require "::/gui/main/content_card.tl"
	local lang_util = ug_require "::/scripts/lang_util.tl"
	local classes = ug_require "kampfmoehre_running_costs_1::/running_costs/cost_classes.lua"
	local cost_rows = ug_require "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/cost_rows.lua"
	local cost_history = ug_require "kampfmoehre_running_costs_1::/running_costs/cost_history.lua"

	local function round(x) return math.floor(x + 0.5) end
	local function money(x) return api.util.formatMoney(round(x or 0)) end
	local function fmt(key, values) return lang_util.format(_(key), values or {}) end

	local function yearMs()
		local ok, y = pcall(api.util.getDefaultYearDuration)
		return (ok and type(y) == "number" and y > 0) and y or DEFAULT_YEAR_MS
	end

	local function gameTime()
		local ok, gt = pcall(api.engine.getComponent, api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return (ok and gt and gt.gameTime) or 0
	end

	-- TransportVehicleState value -> enum name (cost_classes.classify input)
	local STATE_NAMES = { "IN_DEPOT", "EN_ROUTE", "AT_TERMINAL", "GOING_TO_DEPOT" }
	local stateNameOf = nil
	local function stateName(value)
		if stateNameOf == nil then
			stateNameOf = {}
			local enum = api.type["enum"] and api.type["enum"].TransportVehicleState
			if enum then
				for __, name in ipairs(STATE_NAMES) do
					if enum[name] ~= nil then stateNameOf[enum[name]] = name end
				end
			end
		end
		return stateNameOf[value] or tostring(value)
	end

	-- static (healthy) running cost per year of a consist, cached per model id
	local modelStatic = {}
	local function staticPerYear(tv)
		local sum = 0
		local cfg = tv and tv.transportVehicleConfig
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

	-- Reading the sampler's state --------------------------------------------

	-- game-script entities, cached once found: { [gsName] = entity }
	local gsEntities = {}
	local function resolveEntity(gsName, substring)
		if gsEntities[gsName] ~= nil then return gsEntities[gsName] end
		local ok, e = pcall(api.engine.system.gameScriptSystem.getEntityForGameScript, gsName)
		if ok and type(e) == "number" and e >= 0 then
			gsEntities[gsName] = e
			return e
		end
		-- the resource name may differ: look for ours by substring
		local okAll, all = pcall(api.res.gameScriptRep.getAll, true)
		if okAll and type(all) == "table" then
			for __, name in pairs(all) do
				if tostring(name):find(substring, 1, true) then
					local ok2, e2 = pcall(api.engine.system.gameScriptSystem.getEntityForGameScript, name)
					if ok2 and type(e2) == "number" and e2 >= 0 then
						gsEntities[gsName] = e2
						return e2
					end
				end
			end
		end
		return nil
	end
	local function resolveGsEntity() return resolveEntity(GS_NAME, "running_costs.gs") end

	-- Summaries are read per vehicle through the native state
	-- (state_native:findPath({"summary", v}):asTable()), so a window with a few
	-- vehicles does not copy the whole state (13 buckets × every vehicle);
	-- if that API is not available the whole state is copied once per
	-- SAMPLE_S and shared by all windows.
	local readPathLogged = false
	local function logReadPath(text)
		if not readPathLogged then
			readPathLogged = true
			log.message(LOG_PREFIX .. "summaries read via " .. text)
		end
	end

	local function gsComponent()
		local e = resolveGsEntity()
		if not e then return nil end
		local ok, gs = pcall(api.engine.getComponent, e, api.type.ComponentType.GAME_SCRIPT)
		return (ok and gs) or nil
	end

	-- Income (0.2.0): one ring per vehicle (or "L<line>") in the sampler's state
	-- under `inc`, read like the summaries ----------------------------------------

	local incomeCopy = { time = nil, v = nil }
	local incomeNativeFailed = false
	local function incomeRingOf(gs, rk)
		if not gs then return nil end
		if not incomeNativeFailed then
			local ok, r = pcall(function()
				local native = gs.state_native
				if native == nil then return "nostate" end
				local nv = native:findPath({ "inc", rk })
				if nv == nil then return false end
				return nv:asTable()
			end)
			if ok then
				if type(r) == "table" then return r end
				return nil   -- no ring for this key yet, or no state yet
			end
			incomeNativeFailed = true
			log.message(LOG_PREFIX .. "income rings read via a copy of the whole state (findPath/asTable unavailable)")
		end
		local now = gameTime()
		if incomeCopy.time == nil or now - incomeCopy.time >= SAMPLE_S * 1000 or now < incomeCopy.time then
			local okS, st = pcall(function() return gs.state end)
			incomeCopy.time, incomeCopy.v = now, (okS and type(st) == "table" and type(st.inc) == "table") and st.inc or nil
		end
		if not incomeCopy.v then return nil end
		return incomeCopy.v[rk] or incomeCopy.v[tostring(rk)]
	end

	-- income booked on an account over [t0, t1]: the game's own "last year"
	-- figure of the entity (calculateBalance(..., true) = income − running
	-- costs, see line_react_util.LineBalance) minus the two maintenance types
	-- a vehicle/line account carries (VEHICLE = running costs,
	-- VEHICLE_MAINTENANCE = maintenance station). Measured: the income entries
	-- of such an account answer to the type OTHER, so OTHER (and INFRASTRUCTURE)
	-- must not be subtracted. Every term only changes when the game books, so
	-- the result is stable between bookings. nil when unreadable.
	local INCOME_DEBUG = 0   -- log the first N computations with all four types (0 = off)
	local function typed(account, t0, t1, name)
		local t = api.type.JournalEntry.Maintenance[name]
		if t == nil then return 0 end
		local ok, v = pcall(api.engine.util.finance.calculateBalance, { account }, t0, t1, true, t)
		return (ok and type(v) == "number") and v or 0
	end
	local function bookedIncome(account, t0, t1)
		if account == nil or t1 - t0 < 2 * BOOKING_LUMP_MS then return nil end
		local ok, net = pcall(api.engine.util.finance.calculateBalance, { account }, t0, t1, true)
		if not ok or type(net) ~= "number" then return nil end
		local vehicle = typed(account, t0, t1, "VEHICLE")
		local station = typed(account, t0, t1, "VEHICLE_MAINTENANCE")
		local income = net - vehicle - station
		if INCOME_DEBUG > 0 then
			INCOME_DEBUG = INCOME_DEBUG - 1
			log.message(LOG_PREFIX .. string.format("debug income: account=%s net=%s VEHICLE=%s VEHICLE_MAINTENANCE=%s INFRASTRUCTURE=%s OTHER=%s -> income=%s",
				tostring(account), tostring(net), tostring(vehicle), tostring(station),
				tostring(typed(account, t0, t1, "INFRASTRUCTURE")), tostring(typed(account, t0, t1, "OTHER")), tostring(income)))
		end
		return math.max(0, income)
	end

	-- one TRANSPORT_VEHICLE read per vehicle: the income the game has not booked
	-- yet (booked at departure; the events arrive per item while unloading)
	-- and the capacity per cargo type (config.capacities[cargoTypeId + 1])
	local function vehicleFacts(vehicles)
		local pending, caps = 0, {}
		for __, v in ipairs(vehicles or {}) do
			local okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
			if okT and tv then
				local pi = tv.unloadPendingIncome
				if pi and type(pi.amount) == "number" and pi.amount > 0 then pending = pending + pi.amount end
				local c = tv.config and tv.config.capacities
				if type(c) == "table" then
					for i, cap in ipairs(c) do
						if type(cap) == "number" and cap > 0 then caps[i - 1] = (caps[i - 1] or 0) + cap end
					end
				end
			end
		end
		return pending, caps
	end

	local cargoInfo = {}   -- key -> { name, icon }
	local function cargoNameAndIcon(key)
		local c = cargoInfo[key]
		if c then return c.name, c.icon end
		c = { name = tostring(key), icon = nil }
		local ok, ct = pcall(api.res.cargoTypeRep.get, key)
		if ok and ct then
			if type(ct.name) == "string" and ct.name ~= "" then
				local okN, translated = pcall(_, ct.name)
				c.name = (okN and type(translated) == "string" and translated ~= "") and translated or ct.name
			end
			if type(ct.icon) == "string" and ct.icon ~= "" then c.icon = ct.icon end
		end
		cargoInfo[key] = c
		return c.name, c.icon
	end

	-- entries of the vehicles' income rings over the cost window; summaries give first
	local debugRings = 0   -- log the first N ring reads (0 = off)
	-- line: items the collector could not attribute to a vehicle live under "L<line>"
	local function incomeEntries(gs, vehicles, summaries, now, windowMs, line)
		local list = {}
		if line ~= nil then
			local firstMin = nil
			for i in ipairs(vehicles) do
				local w = summaries[i]
				if w and w.first and (firstMin == nil or w.first < firstMin) then firstMin = w.first end
			end
			list[#list + 1] = cost_history.windowIncome(incomeRingOf(gs, "L" .. line), now, windowMs, firstMin)
		end
		for i, v in ipairs(vehicles) do
			local w = summaries[i]
			if w then
				local ring = incomeRingOf(gs, v)
				local entries = cost_history.windowIncome(ring, now, windowMs, w.first)
				if debugRings > 0 then
					debugRings = debugRings - 1
					local nb, keys = 0, {}
					if type(ring) == "table" and type(ring.b) == "table" then
						for __, b in pairs(ring.b) do
							nb = nb + 1
							for k in pairs(b.inc or {}) do keys[#keys + 1] = tostring(k) end
						end
					end
					log.message(LOG_PREFIX .. string.format("debug ring v=%s gsI=%s ring=%s buckets=%d keys=%s first=%s now=%d",
						tostring(v), tostring(gsI ~= nil), type(ring), nb, table.concat(keys, ","), tostring(w.first), now))
				end
				list[#list + 1] = entries
			end
		end
		return cost_rows.mergeIncome(list)
	end

	-- nil = untested, true/false after the first attempt that reached a state
	local nativeWorks = nil
	-- -> table (summary), false (state present, no entry for v), "nostate"
	--    (the script has no state yet), nil (findPath/asTable failed)
	local function nativeSummary(gs, v)
		local ok, w = pcall(function()
			local native = gs.state_native
			if native == nil then return "nostate" end
			local nv = native:findPath({ "summary", v })
			if nv == nil then return false end
			return nv:asTable()
		end)
		if not ok then return nil end
		return w
	end

	local cache = { time = nil, all = nil }
	local function copiedSummaries()
		local now = gameTime()
		if cache.time ~= nil and now - cache.time < SAMPLE_S * 1000 and now >= cache.time then
			return cache.all
		end
		local all = nil
		local gs = gsComponent()
		if gs then
			local okS, st = pcall(function() return gs.state end)
			if okS and type(st) == "table" and type(st.summary) == "table" then all = st.summary end
		end
		cache.time, cache.all = now, all
		return all
	end

	-- Summary of one vehicle or nil; gs = the GAME_SCRIPT component (fetched
	-- once per table refresh by the caller, may be nil)
	local function summaryOf(gs, v)
		if nativeWorks ~= false then
			if gs then
				local w = nativeSummary(gs, v)
				if type(w) == "table" then
					if nativeWorks == nil then logReadPath("state_native:findPath per vehicle") end
					nativeWorks = true
					return w
				elseif w == false then
					-- the state exists but has no entry for this vehicle (yet)
					if nativeWorks == nil then logReadPath("state_native:findPath per vehicle") end
					nativeWorks = true
					return nil
				elseif w == "nostate" then
					return nil   -- nothing sampled yet; decide later
				end
				-- findPath/asTable threw: this build has no usable native path
				nativeWorks = false
				logReadPath("a copy of the whole state (findPath/asTable unavailable)")
			end
		end
		local all = copiedSummaries()
		if not all then return nil end
		return all[v] or all[tostring(v)]
	end

	local function lineVehicles(line)
		local ok, vs = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, line)
		return (ok and type(vs) == "table") and vs or {}
	end

	local function entityName(e)
		local ok, n = pcall(api.engine.util.getEntityName, e)
		return (ok and n) or tostring(e)
	end

	-- The table -----------------------------------------------------------------

	-- p = { vehicles = {entity}? , line = entity? }
	local function tableData(p)
		local vehicles = p.line and lineVehicles(p.line) or (p.vehicles or {})
		local list, names, byIndex = {}, {}, {}
		local gs = gsComponent()
		for i, v in ipairs(vehicles) do
			local w = summaryOf(gs, v)
			if w then
				list[#list + 1] = w
				names[#names + 1] = { v = v, cov = w.cov or 0 }
				byIndex[i] = w
			end
		end
		local T = cost_rows.build(list, classes)
		T.booked = nil
		T.lessTooltip = nil
		if not T.empty then
			if T.lessData > 0 then
				local lines = { _("running_costs_less_data_tooltip") }
				for __, n in ipairs(names) do
					if n.cov < T.coverageMs - cost_rows.COVERAGE_TOLERANCE_MS then
						lines[#lines + 1] = entityName(n.v) .. ": " .. cost_rows.minutes(n.cov) .. " min"
					end
				end
				T.lessTooltip = table.concat(lines, "\n")
			end
			-- the game books in 60 s lumps: compare only once the window holds two
			local account = p.line or vehicles[1]
			if account and T.coverageMs >= 2 * BOOKING_LUMP_MS then
				local now = gameTime()
				local ok, b = pcall(api.engine.util.finance.calculateBalance, { account }, now - T.coverageMs, now, true,
					api.type.JournalEntry.Maintenance.VEHICLE)
				if ok and type(b) == "number" then T.booked = -b end
			end
		end
		-- income of the same window (0.2.0)
		T.income, T.result = nil, nil
		if not T.empty then
			local now = gameTime()
			local win = yearMs()
			local entries = incomeEntries(gs, vehicles, byIndex, now, win, p.line)
			local pending, caps = vehicleFacts(vehicles)
			local account = p.line or vehicles[1]
			local booked = bookedIncome(account, now - T.coverageMs, now)
			if booked ~= nil then booked = booked + pending end
			local factor = cost_rows.scaleFactor(entries, booked)
			local mode = factor and "own" or "raw"
			if factor == nil and p.line == nil and vehicles[1] then
				-- no usable vehicle account: the line's factor (the company-level multiplier is uniform)
				local okT, tv = pcall(api.engine.getComponent, vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
				local line = okT and tv and tv.line
				if type(line) == "number" and line >= 0 then
					local lv = lineVehicles(line)
					local ls = {}
					for i, v in ipairs(lv) do ls[i] = summaryOf(gs, v) end
					local lineEntries = incomeEntries(gs, lv, ls, now, win, line)
					local lineBooked = bookedIncome(line, now - T.coverageMs, now)
					if lineBooked ~= nil then lineBooked = lineBooked + (vehicleFacts(lv)) end
					local lf = cost_rows.scaleFactor(lineEntries, lineBooked)
					if lf then factor, mode = lf, "line" end
				end
			end
			-- an account that is readable but has no income in the window still counts as "scaled"
			local bookedKnown = (booked ~= nil) or mode == "line"
			local TI = cost_rows.buildIncome(entries, factor, function(k) return (cargoNameAndIcon(k)) end, bookedKnown)
			TI.mode = mode
			TI.booked = (mode == "own") and booked or nil
			TI.pending = (mode == "own") and pending or 0
			TI.capacity = {}
			for __, r in ipairs(TI.rows) do TI.capacity[r.key] = caps[r.key] end
			T.income = TI
			T.result = cost_rows.result(TI, T)
		end
		-- signature for cheap change detection
		local sig = { tostring(T.empty), tostring(T.coverageMs), tostring(T.lessData), tostring(round(T.sum)), tostring(T.booked and round(T.booked) or "") }
		for __, r in ipairs(T.rows) do sig[#sig + 1] = r.key .. ":" .. round(r.amount) .. ":" .. round(r.share * 1000) end
		if T.surcharge then sig[#sig + 1] = "s:" .. round(T.surcharge.amount) end
		if T.income then
			sig[#sig + 1] = "i:" .. T.income.mode .. ":" .. round(T.income.sum.income) .. ":" .. #T.income.rows .. ":" .. tostring(T.result and round(T.result) or "") .. ":" .. round(T.income.pending or 0)
			for __, r in ipairs(T.income.rows) do sig[#sig + 1] = tostring(r.key) .. "=" .. r.n .. ":" .. round(r.income) .. ":" .. tostring(T.income.capacity[r.key]) end
		end
		T.sig = table.concat(sig, "|")
		return T
	end

	local function colourClass(colour)
		if colour == "ok" then return ", kampfmoehre-rc-ok" end
		if colour == "warn" then return ", kampfmoehre-rc-warn" end
		if colour == "off" then return ", kampfmoehre-rc-off" end
		return ""
	end

	local function classLabel(r)
		return fmt(r.labelKey, { factor = tostring(round(r.factor * 100)) })
	end

	local CostTable = react.RegisterRecipe("KampfmoehreRunningCostsTable", function(p)
		local state = react.useStateLazy(function() return tableData(p) end)
		react.onStepTimer(function()
			local now = tableData(p)
			if now.sig ~= state:old().sig then state:set(now) end
		end, SAMPLE_S)
		local T = state:old()
		local function cell(text, class)
			return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = text }
		end
		if T.empty then
			return builtin.BoxLayout{ children = { cell(_("running_costs_no_data")) } }
		end
		local children = {}
		-- a Component's layout must be a layout, not a TextView
		children[#children + 1] = builtin.Component{
			meta = { tooltip = _("running_costs_header_tooltip") },
			layout = builtin.BoxLayout{ children = { cell(fmt("running_costs_header", { minutes = tostring(cost_rows.minutes(T.coverageMs)) })) } },
		}
		if T.lessData > 0 then
			children[#children + 1] = builtin.Component{
				meta = { tooltip = T.lessTooltip or "" },
				layout = builtin.BoxLayout{ children = { cell(fmt(cost_rows.lessDataKey(T.lessData), { n = tostring(T.lessData) }), "font-scale-annotation") } },
			}
		end
		local rows = { builtin.Row{ cells = {
			cell(_("running_costs_col_state"), "font-scale-annotation"),
			cell(_("running_costs_col_time"), "font-scale-annotation"),
			cell(_("running_costs_col_cost"), "font-scale-annotation, kampfmoehre-rc-money"),
		} } }
		for __, r in ipairs(T.rows) do
			rows[#rows + 1] = builtin.Row{ cells = {
				cell(classLabel(r)),
				builtin.Component{
					meta = { class = "kampfmoehre-rc-barcell" },
					layout = builtin.BoxLayout{
						orientation = builtin.type.Orientation.Horizontal,
						children = {
							builtin.ProgressBar{
								meta = { class = "font-scale-annotation, kampfmoehre-rc-bar" .. colourClass(r.colour) },
								value = r.share,
								label = string.format("%d %%", round(r.share * 100)),
							},
						},
					},
				},
				cell(money(r.amount), "font-scale-body, negative, kampfmoehre-rc-money"),
			} }
		end
		if T.surcharge then
			rows[#rows + 1] = builtin.Row{ cells = {
				cell(fmt("running_costs_class_surcharge", { pct = tostring(T.surcharge.pct and round(T.surcharge.pct) or 0) })),
				cell(""),
				cell(money(T.surcharge.amount), "font-scale-body, negative, kampfmoehre-rc-money"),
			} }
		end
		rows[#rows + 1] = builtin.Row{ cells = {
			cell(_("running_costs_sum"), "font-scale-body, bold"),
			cell(""),
			cell(money(T.sum), "font-scale-body, bold, negative, kampfmoehre-rc-money"),
		} }
		children[#children + 1] = builtin.TableLayout{ rows = rows, columnWeights = { -1, 10, -1 } }
		if T.booked then
			children[#children + 1] = cell(fmt("running_costs_booked", { amount = money(T.booked) }), "font-scale-annotation")
		end
		-- income table (0.2.0)
		local TI = T.income
		if TI then
			children[#children + 1] = builtin.Component{
				meta = { tooltip = _("running_costs_header_tooltip") },
				layout = builtin.BoxLayout{ children = { cell(fmt("running_costs_income_header", { minutes = tostring(cost_rows.minutes(T.coverageMs)) })) } },
			}
			if TI.empty then
				children[#children + 1] = cell(_("running_costs_no_income"))
				if TI.mode == "own" and TI.booked and TI.booked > 0 then
					children[#children + 1] = cell(fmt("running_costs_income_booked", { amount = money(TI.booked) }), "font-scale-annotation")
				end
			else
				local irows = { builtin.Row{ cells = {
					cell(_("running_costs_col_cargo"), "font-scale-annotation"),
					cell(_("running_costs_col_items"), "font-scale-annotation, kampfmoehre-rc-num"),
					cell(_("running_costs_col_income"), "font-scale-annotation, kampfmoehre-rc-money"),
					cell(_("running_costs_col_per_item"), "font-scale-annotation, kampfmoehre-rc-money"),
					cell(_("running_costs_col_on_time"), "font-scale-annotation, kampfmoehre-rc-num"),
					cell(_("running_costs_col_capacity"), "font-scale-annotation, kampfmoehre-rc-num"),
				} } }
				for __, r in ipairs(TI.rows) do
					local name, icon = cargoNameAndIcon(r.key)
					local cargoCell
					if icon then
						cargoCell = builtin.Component{
							meta = { tooltip = name },
							layout = builtin.BoxLayout{ children = {
								builtin.ImageView{ meta = { class = "kampfmoehre-rc-cargo" }, path = icon, scaling = builtin.type.ImageViewScaling.AutoFit },
							} },
						}
					else
						cargoCell = cell(name)
					end
					local cap = TI.capacity[r.key]
					irows[#irows + 1] = builtin.Row{ cells = {
						cargoCell,
						cell(tostring(r.n), "font-scale-body, kampfmoehre-rc-num"),
						cell(money(r.income), "font-scale-body, positive, kampfmoehre-rc-money"),
						cell(r.perItem and money(r.perItem) or "–", "font-scale-body, kampfmoehre-rc-money"),
						cell(r.onTimeShare and string.format("%d %%", round(r.onTimeShare * 100)) or "–", "font-scale-body, kampfmoehre-rc-num"),
						cell(cap and tostring(cap) or "–", "font-scale-body, kampfmoehre-rc-num"),
					} }
				end
				irows[#irows + 1] = builtin.Row{ cells = {
					cell(_("running_costs_sum"), "font-scale-body, bold"),
					cell(tostring(TI.sum.n), "font-scale-body, bold, kampfmoehre-rc-num"),
					cell(money(TI.sum.income), "font-scale-body, bold, positive, kampfmoehre-rc-money"),
					cell(""), cell(""), cell(""),
				} }
				children[#children + 1] = builtin.TableLayout{ rows = irows, columnWeights = { -1, -1, -1, -1, -1, -1 } }
				if TI.mode == "own" and TI.booked then
					if (TI.pending or 0) > 0 then
						children[#children + 1] = cell(fmt("running_costs_income_booked_pending", { amount = money(TI.booked), pending = money(TI.pending) }), "font-scale-annotation")
					else
						children[#children + 1] = cell(fmt("running_costs_income_booked", { amount = money(TI.booked) }), "font-scale-annotation")
					end
				elseif TI.mode == "line" then
					children[#children + 1] = cell(_("running_costs_income_line_factor"), "font-scale-annotation")
				else
					children[#children + 1] = cell(_("running_costs_income_raw"), "font-scale-annotation")
				end
			end
			-- result line
			if T.result ~= nil then
				children[#children + 1] = builtin.Component{
					meta = { tooltip = _("running_costs_result_tooltip") },
					layout = builtin.BoxLayout{ children = {
						cell(fmt("running_costs_result", { amount = money(T.result) }), "font-scale-body, bold, " .. (T.result >= 0 and "positive" or "negative")),
					} },
				}
			else
				children[#children + 1] = builtin.Component{
					meta = { tooltip = _("running_costs_income_raw") },
					layout = builtin.BoxLayout{ children = { cell(fmt("running_costs_result", { amount = "–" }), "font-scale-body, bold") } },
				}
			end
		end
		return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
	end)

	-- Vehicle window: live line + collapsible table -------------------------------

	local function liveData(v)
		local okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if not okT or not tv then return nil end
		local okR, rc = pcall(api.engine.util.vehicle.getRunningCost, v)
		local okS, speed = pcall(api.engine.util.vehicle.getSpeed, v)
		local key = classes.classify(stateName(tv.state), (okS and speed) or 0)
		local L = cost_rows.live((okR and rc) or 0, staticPerYear(tv), key, classes)
		L.key = key
		return L
	end

	local function sameLive(a, b)
		if not a or not b then return (a or nil) == (b or nil) end
		return a.key == b.key and round(a.perMin) == round(b.perMin) and a.surchargePct == b.surchargePct
	end

	local function liveText(L)
		if not L then return _("running_costs_no_data"), "" end
		local cl = classes.byKey[L.key]
		local text = fmt("running_costs_now", { rate = money(L.perMin) })
			.. " · " .. fmt(cl and cl.shortKey or "running_costs_short_driving", { factor = tostring(round(L.factor * 100)) })
		if L.surchargePct > 0 then
			text = text .. " · " .. fmt("running_costs_condition", { pct = tostring(L.surchargePct) })
		end
		local class = ""
		if L.colour == "ok" or L.colour == "off" then class = ", success"
		elseif L.colour == "warn" then class = ", kampfmoehre-rc-warn" end
		return text, class
	end

	local M = {}

	M.VehiclePlugin = react.RegisterPluginRecipe(
		{ id = "::VehicleEowExtensionPoint" }, "KampfmoehreRunningCostsVehicle",
		function(params)
			-- false instead of nil: a react state must hold a value
			local state = react.useStateLazy(function() return liveData(params.entityId) or false end)
			react.onStepTimer(function()
				local now = liveData(params.entityId) or false
				if not sameLive(now, state:old()) then state:set(now) end
			end, 1)
			local text, class = liveText(state:old())
			local canCollapse = type(params.getCollapsibleExpanded) == "function" and type(params.setCollapsibleExpanded) == "function"
			local tooltip = fmt("running_costs_vehicle_tooltip", { minutes = tostring(cost_rows.minutes(yearMs())) })
			return builtin.BoxLayout{
				meta = { class = "box-plugin-vertical-space" },
				orientation = builtin.type.Orientation.Vertical,
				children = {
					content_card.ContentCard{
						initialCalloutTextPermanent = "",
						extraChildrenPermanent = {
							builtin.Component{
								meta = { tooltip = tooltip },
								layout = builtin.BoxLayout{
									orientation = builtin.type.Orientation.Horizontal,
									children = {
										builtin.ImageView{
											path = "::/gui/entity_window/icons/symbol_dollar_gear.tga",
											scaling = builtin.type.ImageViewScaling.AutoFit,
										},
										builtin.TextView{
											meta = { class = "font-scale-body" .. class },
											text = "  " .. text,
										},
									},
								},
							},
						},
						initialCalloutTextCollapsible = canCollapse and "" or nil,
						recipeAndParamCollapsible = canCollapse and content_card.makeRecipeAndParam(CostTable, { vehicles = { params.entityId } }) or nil,
						setCollapsibleExpanded = canCollapse and function(v) params.setCollapsibleExpanded(CARD_KEY, v) end or nil,
						collapsibleExpanded = canCollapse and params.getCollapsibleExpanded(CARD_KEY) or nil,
						gameCtx = params.gameCtx,
						showOnRightSide = params.showCalloutOnRightSide,
					},
				},
			}
		end)

	-- Line window: the table inside the "Balance" card -------------------------

	-- renders the game's balance graph recipe plus our table for the line
	local BalanceWithCosts = react.RegisterRecipe("KampfmoehreRunningCostsBalance", function(p)
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = {
				p.inner.recipe(p.inner.param),
				CostTable{ line = p.line },
			},
		}
	end)

	-- Wrap content_card.ContentCard (the module table is shared with the base
	-- scripts, so line_eow's call reaches this function). Only the card with
	-- localKey "lineBalance" is touched; forward all arguments.
	local origContentCard = content_card.ContentCard
	content_card.ContentCard = function(...)
		local n = select('#', ...)
		local params = select(n, ...)
		if type(params) == "table" and type(params.meta) == "table" and params.meta.localKey == "lineBalance"
			and type(params.recipeAndParamPermanent) == "table" and params.recipeAndParamPermanent.recipe ~= BalanceWithCosts then
			local inner = params.recipeAndParamPermanent
			local line = type(inner.param) == "table" and inner.param.entityId or nil
			if line ~= nil then
				params.recipeAndParamPermanent = content_card.makeRecipeAndParam(BalanceWithCosts, { inner = inner, line = line })
			end
		end
		return origContentCard(...)
	end

	log.message(LOG_PREFIX .. "v" .. VERSION .. " GUI loaded (vehicle row, balance card table)")

	return M
end
