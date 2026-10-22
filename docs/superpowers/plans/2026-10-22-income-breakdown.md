# Income Breakdown (0.2.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under the running-cost table of vehicle and line windows, a second table with the income of the same rolling window per cargo type (items, income, per item, on-time share, capacity) and a result line income − costs.

**Architecture:** A second, event-only game script (`income.gs.lua` + `income.script.lua`) listens to `OnCalcTicketPrice` and accumulates items, base income and on-time counts per vehicle, cargo type and time bucket into its own small state, using the bucket ring factored out of `cost_history.lua`. The GUI reads one income ring per vehicle via `state_native:findPath`, derives window sums with the cost history's coverage and `first`, scales base income to the booked income of the line's or vehicle's account (pure `cost_rows.buildIncome`), and renders the table and the result line inside the existing `CostTable` recipe.

**Tech Stack:** Lua 5.1 / LuaJIT, TF3 game scripts and react-like GUI, luajit tests. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-21-income-breakdown-design.md` (this repo); the 0.1.x design `docs/superpowers/specs/2026-10-20-running-cost-breakdown-design.md`; conventions `/home/satan/dev/tpf3-modding/CLAUDE.md`.

## Global Constraints

- Same repo, modId `kampfmoehre_running_costs_1`, log prefix `[kampfmoehre_running_costs]`; `VERSION = "0.2.0"` in all three scripts (cost sampler, income script, GUI), `mod.json` `revision` 3, `cosmetic: true`, no params.
- **No commits by the implementer** unless the user asks (CLAUDE.md); each task ends with the changed files and a suggested conventional commit message. The user tests in game before upload.
- The `OnCalcTicketPrice` handler **never returns a value** (a returned table changes prices).
- Game scripts: `handleEvent` runs on an arbitrary sim-pool thread with its own Lua state; everything persistent goes through `state:get()`/`state:set()`; lifecycle events (`id == ""`, names `initNewGame`, `initNewGameFromMap`, `initMission`, `handleLegacy`) arrive without subscription; `OnCalcTicketPrice` needs `state:subscribeToEvent`.
- Budget for the income script: ≤ 1 ms of one pool thread per second of game time on the 364-vehicle save, measured with `api.type.Clock`, logged every 300 s of game time. Exceeding it is reported, not silently optimised.
- Window, coverage, pro-rata weight and "n vehicles with less data" come from the **cost** history of each vehicle (`summary.cov`, `summary.first`); the income ring carries no `first`.
- Rolling window = `api.util.getDefaultYearDuration()` ms; bucket geometry `cost_history.BUCKET_MS = 243500`, `BUCKETS = 7`, shared by both rings.
- GUI rules: no `_` loop variables, no globals, `pcall` around engine calls, `builtin.Component{ layout = <layout> }`, amounts right-aligned (`kampfmoehre-rc-money`), counts right-aligned (new `kampfmoehre-rc-num`), money via `api.util.formatMoney`.
- Texts EN first in `strings.json` (keys and EN copy pinned in Task 4), DE by the implementer, user reviews; `luajit -bl` every Lua file; `luajit test/<name>_test.lua` from the repo root.

## Review Focus

- A vehicle that moved to another line inside the window: its income stays with the vehicle and the new line's table sums it, exactly like its costs. Test in Task 3 (`mergeIncome` has no notion of lines) and in-game check in Task 4.
- A cargo type the game no longer knows (mod removed): the row shows the numeric id instead of a name and the table still renders. Test in Task 3 (`buildIncome` with a `nameOf` that returns nil) and Task 4 renders `tostring(key)`.
- Deliveries with zero base income (distance 0, refunds): no division by zero in "per item", no NaN in the scale factor. Tests in Task 3 (`perItem` with `n > 0, base = 0`; factor rule with `Σ base = 0`).
- Booked income ≤ 0 or unreadable: the table falls back along the chain own account → line factor → raw, and the result line disappears in raw mode instead of showing a pre-multiplier "result". Tests in Task 3 (`scaleFactor` returns nil for `booked ≤ 0`, `result` returns nil when not scaled).
- Passengers (no delivery quality): the on-time cell shows "–", never "0 %". Test in Task 3 (`onTimeShare == nil` when `q == 0`).

---

## File structure

```
kampfmoehre_running_costs_1/
  content/running_costs/cost_history.lua        + newRing, bucketFor (exported), bucketWeight, addIncome, windowIncome (Task 1)
  content/running_costs/income.gs.lua           handleEventScript registration (Task 2)
  content/running_costs/income.script.lua       OnCalcTicketPrice collector, own state (Task 2)
  content/running_costs/running_costs.script.lua  summary.first added, VERSION 0.2.0 (Task 2)
  content/gui/kampfmoehre_running_costs/cost_rows.lua       + mergeIncome, scaleFactor, buildIncome, result (Task 3)
  content/gui/kampfmoehre_running_costs/running_costs.script.lua  income reader, booked income, capacity, income table, result line (Task 4)
  content/gui/kampfmoehre_running_costs/running_costs.css.lua     + kampfmoehre-rc-num (Task 4)
  strings.json                                   + income keys EN/DE (Task 4)
  mod.json, _metadata/modinfo.json, README.md, CHANGELOG.md (Task 5)
test/cost_history_test.lua, test/cost_rows_test.lua           extended (Tasks 1, 3)
```

---

### Task 1: Shared bucket ring and income accumulation (pure)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/cost_history.lua`
- Test: `test/cost_history_test.lua` (append)

**Interfaces:**
- Produces (all in `cost_history`, existing functions unchanged in behaviour):
  - `M.newRing(nowMs) : Ring` — `{ start, head = 0, b = {} }`, no `first`. `M.new(nowMs)` keeps returning a ring plus `first`.
  - `M.bucketFor(ring, nowMs) : Bucket` — exported version of the current local; creates `{ t0 }` only (the cost `add` keeps initialising `t`/`r`/`s` lazily); on a step back in time it resets the ring and sets `first = nowMs` only if the ring has a `first`.
  - `M.bucketWeight(t0, nowMs, windowMs, first) : number` — 0 if the bucket does not overlap `[nowMs − windowMs, nowMs]` or `t0 > nowMs`; otherwise the current pro-rata rule with `dataStart = max(t0, first or t0)`. `M.window` uses it (same results as today).
  - `M.addIncome(ring, nowMs, key, base, ok)` — `bucket.inc[key] = { n, base, ok, q }`: `n += 1`, `base += base`, `q += 1` if `ok ~= nil`, `ok += 1` if `ok == true`.
  - `M.windowIncome(ring, nowMs, windowMs, first) : { [key] = { n, base, ok, q } }` — weighted with `bucketWeight` (fractional `n` allowed); unknown or sparse buckets tolerated; an empty or nil ring gives `{}`.

- [ ] **Step 1: Append the failing tests** to `test/cost_history_test.lua` (reuse `check`/`near`, `Y`, `W`):

```lua
-- shared ring: income without time accumulation
local r = M.newRing(0)
check("ring has no first", r.first == nil and r.head == 0)
M.addIncome(r, 1000, 7, 500, true)
M.addIncome(r, 2000, 7, 300, false)
M.addIncome(r, 3000, 9, 100, nil)                     -- passengers: no quality
local I = M.windowIncome(r, 3000, Y, nil)
near("items", I[7].n, 2, 1e-9); near("base", I[7].base, 800, 1e-9)
check("on time 1 of 2 with quality", I[7].ok == 1 and I[7].q == 2)
check("no quality counted", I[9].n == 1 and I[9].q == 0 and I[9].ok == 0)
-- the window cut uses the cost history's first, pro rata like the costs
local r2 = M.newRing(0)
M.addIncome(r2, M.BUCKET_MS / 2 + 1000, 7, 1000, true)                  -- bucket 0, data from first = B/2
local I2 = M.windowIncome(r2, M.BUCKET_MS + 10, M.BUCKET_MS / 4 + 10, M.BUCKET_MS / 2)
near("income pro rata against first", I2[7].base, 500, 1e-6)
near("items pro rata too", I2[7].n, 0.5, 1e-9)
check("empty ring", next(M.windowIncome(M.newRing(0), 0, Y, nil)) == nil and next(M.windowIncome(nil, 0, Y, nil)) == nil)
-- bucketWeight is the single rule both windows use
near("weight: full bucket", M.bucketWeight(0, 2 * M.BUCKET_MS, 3 * M.BUCKET_MS, nil), 1, 1e-9)
near("weight: outside", M.bucketWeight(0, 10 * M.BUCKET_MS, M.BUCKET_MS, nil), 0, 1e-9)
near("weight: half cut, first mid-bucket", M.bucketWeight(0, M.BUCKET_MS + 10, M.BUCKET_MS / 4 + 10, M.BUCKET_MS / 2), 0.5, 1e-9)
-- exported bucketFor keeps the ring bounded and resets on backwards time
local r3 = M.newRing(0)
for i = 0, 9 do M.bucketFor(r3, i * M.BUCKET_MS) end
local n3 = 0; for __ in pairs(r3.b) do n3 = n3 + 1 end
check("ring bounded", n3 == M.BUCKETS)
M.bucketFor(r3, 5); check("reset on backwards time without first", r3.head == 1 and r3.first == nil)
```

- [ ] **Step 2: Run `luajit test/cost_history_test.lua`** — Expected: FAIL (`newRing` nil).
- [ ] **Step 3: Implement** `newRing`, export `bucketFor`, extract `bucketWeight`, rewrite `window()` to use it, add `addIncome` and `windowIncome`. `new()` = `newRing()` + `first`.
- [ ] **Step 4: Run all three test files** — Expected: all `ok` (the existing cost tests prove `window()` unchanged). `luajit -bl` the module.
- [ ] **Step 5: Report** files + `feat: shared bucket ring with income accumulation`.

---

### Task 2: Income game script (engine)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/running_costs/income.gs.lua` — `data()` → `{ handleEventScript = { fileName = "income.script@handleEvent" } }`.
- Create: `kampfmoehre_running_costs_1/content/running_costs/income.script.lua`.
- Modify: `kampfmoehre_running_costs_1/content/running_costs/running_costs.script.lua` — `VERSION = "0.2.0"`; in `sample()` set `w.first = h.first` on every summary (additive, STATE_VERSION stays 2).
- Reference: the cost sampler (log helper, state checks, perf), `game-src/game_mechanics/game_mechanics/towns/towns.script.tl:401-430`, `company_growth.script.tl:110-125` (lifecycle subscription), probe pattern for `hasEventSubscriptions`.

**Interfaces:**
- Consumes: `cost_history.newRing`, `bucketFor` (implicitly via `addIncome`), `addIncome`.
- Produces the saved state read by Task 4 under `getEntityForGameScript("kampfmoehre_running_costs_1::/running_costs/income.gs")`:

```lua
state = {
  version = 1,            -- INCOME_STATE_VERSION
  batches = n, items = n, -- since the state was created
  v = { [vehicleEntity] = Ring },   -- cost_history rings with bucket.inc
  perf = { ms = total, n = batches, maxMs = max }, tPerfLog = gameTimeMs,
}
```

- [ ] **Step 1: Write `income.script.lua`** with `function data() return { handleEvent = handleEvent } end` and:
  - constants `VERSION = "0.2.0"`, `INCOME_STATE_VERSION = 1`, `PERF_LOG_MS = 300000`, `CLEANUP_EVERY = 50`, `EVENT = "OnCalcTicketPrice"`, `LIFECYCLE = { initNewGame = true, initNewGameFromMap = true, initMission = true, handleLegacy = true }`; the same `gameLog`/`log` helper and error cap (10 per thread) as the sampler.
  - `freshState(now)` → the table above; used when `type(s) ~= "table" or s.version ~= INCOME_STATE_VERSION or type(s.v) ~= "table"` (log once "income collector v0.2.0 started (fresh state)").
  - `ensureSubscribed(state)`: `if not state:hasEventSubscriptions() then state:subscribeToEvent(EVENT) end`; called on every lifecycle event (`id == "" and LIFECYCLE[name]`) and, as a safety net, on every handled `EVENT` batch.
  - `passengerId()` cached per thread: `api.res.cargoTypeRep.getPassengerCargoTypeId()`.
  - `handleBatch(state, id, param)`: `now` from the world's `GAME_TIME`; `s = state:get()` (or fresh); for each event `e` in `param` (array; skip non-tables): `v = e.vehicleEntity`, `key = (id == "SimEntityAtVehicleSystem") and passengerId() or SIM_CARGO(e.simEntity).cargoType` (skip the item when neither is a number); `base = (e.basePrice or 0) * (e.distance or 0)`; `ok = nil`; `local okQ, q = pcall(api.engine.util.cargo.isGoodQuality, e.simEntity)`; `if okQ and type(q) == "boolean" then ok = q end`; `ring = s.v[v] or newRing(now)`; `addIncome(ring, now, key, base, ok)`; count `items`. Then `batches += 1`; every `CLEANUP_EVERY` batches drop `s.v[v]` where `not api.engine.entityExists(v)`; perf bookkeeping (`Clock` around the whole batch incl. get/set), `state:set(s)`; perf log every `PERF_LOG_MS`: `"income perf: %d batches, %d items, %.2f ms per batch, max %.2f ms"`.
  - `handleEvent(userParams, state, src, id, name, param)`: `pcall` everything; lifecycle → `ensureSubscribed`; `name == EVENT and (id == "TransportVehicleSystem" or id == "SimEntityAtVehicleSystem")` → `ensureSubscribed` + `handleBatch`; **return nothing** in every path.
- [ ] **Step 2: Write `income.gs.lua`; patch the sampler** (`VERSION`, `w.first = h.first`).
- [ ] **Step 3: `luajit -bl` the three files; run the test suite; `./sync.sh`.**
- [ ] **Step 4: In-game check (user, after Task 4 so the table shows the data).** Deviation from the spec's "batches counter per thread": a lost write between two pool threads cannot be told apart from a normal interleave without thread ids, so the check is end-to-end instead: items in the income table vs. the line's "Transportiert" count over the same span (a shortfall of more than a few % = lost batches → serialise through the cost sampler's `update`). Single-truck save: `stdout.txt` has "income collector v0.2.0 started", no `error` lines; after a few deliveries the income perf line shows batches > 0 and items ≥ batches; items in the income table after a full window ≈ the line's "Transportiert" of the same span. Big save: income perf line, ms per batch and batches per 300 s → budget check (≤ 1 ms per game second = batches × ms per batch ≤ 300 per 300 s). If items stay 0 on an existing save, the lifecycle subscription did not fire: report which lifecycle names appeared (add a one-time log of `name` for `id == ""` events behind a `DEBUG_LIFECYCLE = false` flag).
- [ ] **Step 5: Report** files + `feat: income collector game script`.

---

### Task 3: Income rows and result (pure)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/cost_rows.lua`
- Test: `test/cost_rows_test.lua` (append)

**Interfaces:**
- Produces:
  - `M.mergeIncome(list : { { [key] = { n, base, ok, q } } }) : { [key] = { n, base, ok, q } }` — sums per key over vehicles.
  - `M.scaleFactor(entries, booked) : number | nil` — `booked / Σ base` when `booked` is a number `> 0` and `Σ base > 0`, else nil.
  - `M.buildIncome(entries, factor, nameOf, bookedKnown) : Table` — `Table = { rows = { { key, name, n (rounded integer), base, income, perItem | nil, onTimeShare | nil } }, sum = { n, base, income }, scaled, empty }` with `scaled = (factor ~= nil) or (bookedKnown == true and Σ base == 0)` (a readable account with no deliveries is still "scaled": the result line is then minus the costs); `income = base × (factor or 1)`; `perItem = income / n` when `n ≥ 1` else nil; `onTimeShare = ok / q` when `q > 0` else nil; rows with `round(n) == 0` dropped; rows sorted by `income` desc, ties by key; `name = nameOf(key) or tostring(key)`; `empty = (#rows == 0)`.
  - `M.result(incomeTable, costTable) : number | nil` — `incomeTable.sum.income − costTable.sum` when `incomeTable.scaled`, else nil (also nil when `incomeTable.empty` and `costTable.empty`; when only the income is empty and the cost table is scaled-irrelevant, result = `−costTable.sum`).

- [ ] **Step 1: Append the failing tests** to `test/cost_rows_test.lua`:

```lua
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
```

- [ ] **Step 2: Run `luajit test/cost_rows_test.lua`** — Expected: FAIL (`mergeIncome` nil).
- [ ] **Step 3: Implement the four functions** per the Interfaces block.
- [ ] **Step 4: Run the suite** — Expected: all `ok`. `luajit -bl`.
- [ ] **Step 5: Report** files + `feat: income rows, scaling and result`.

---

### Task 4: GUI — income table, result line, strings, CSS

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua` (reader, booked income, capacity, table, result; `VERSION = "0.2.0"`)
- Modify: `running_costs.css.lua` (`R::KampfmoehreRunningCostsTable TextView!kampfmoehre-rc-num { gravity = { 1, 0.5 } }`, `ImageView!kampfmoehre-rc-cargo { size per font class like the bars, scaling AutoFit }`)
- Modify: `strings.json`

**Interfaces:**
- Consumes: Task 1 `windowIncome(ring, now, windowMs, first)`; Task 2 state layout and GS name; Task 3 `mergeIncome`, `scaleFactor`, `buildIncome`, `result`; the existing `tableData(p)`, `gsComponent()`, `summaryOf(gs, v)` (which now returns `first` in the summary), `BOOKING_LUMP_MS`.
- Produces (inside `data()`):
  - `INCOME_GS_NAME = "kampfmoehre_running_costs_1::/running_costs/income.gs"`; `incomeGsComponent()` like `gsComponent()` with its own cached entity (substring fallback `"income.gs"`).
  - `incomeRingOf(gsI, v) : Ring | nil` — `gsI.state_native:findPath({ "v", v })` → `:asTable()`, fallback `gsI.state.v[v]` once per 2 s via the same cache pattern as `copiedSummaries` (only if `findPath` throws).
  - `bookedIncome(account, t0, t1) : number | nil` — `total = calculateBalance({account}, t0, t1, true)`; `income = total − Σ calculateBalance({account}, t0, t1, true, M)` for `M` in `VEHICLE, VEHICLE_MAINTENANCE, INFRASTRUCTURE, OTHER` (each in `pcall`; nil if the total fails); only when `t1 − t0 ≥ 2 × BOOKING_LUMP_MS`.
  - `capacityFor(vehicles, key) : integer | nil` — Σ over vehicles of `TRANSPORT_VEHICLE.config.capacities[key + 1]` (pcall; nil when every vehicle lacks it or the sum is 0).
  - `cargoNameAndIcon(key) : name, iconPath` — `api.res.cargoTypeRep.get(key)` → `_(name)` if it resolves, else `name`, else `tostring(key)`; passengers (`getPassengerCargoTypeId()`) use the game's passenger icon path from the same record.
  - `tableData(p)` gains: `entriesPerVehicle = { windowIncome(ring, now, yearMs, summary.first) }` for the same vehicles that contributed cost summaries (a vehicle without a ring contributes `{}`); `entries = mergeIncome(...)`; scaling chain: `booked = bookedIncome(p.line or vehicles[1], now − T.coverageMs, now)` → own account; if nil and `p.line == nil`: `lineFactor` from the vehicle's line (`tv.line`, its vehicles' rings and the line account, cached per line for 2 s); `factor = scaleFactor(entries, booked)` or the line factor; `TI = buildIncome(entries, factor, nameOf, booked ~= nil)`; `TI.mode = "own" | "line" | "raw"`; `TI.capacity[key] = capacityFor(vehicles, key)` per row; `T.income = TI`; `T.result = cost_rows.result(TI, T)`; the signature string extends with `round(TI.sum.income)`, `TI.mode`, `#TI.rows`, `T.result`.
  - Rendering in `CostTable` after the cost table: header `running_costs_income_header` (same `{minutes}`) with the header tooltip; if `TI.empty` → one TextView `running_costs_no_income`; else a `TableLayout{ columnWeights = { -1, -1, -1, -1, -1, -1 } }` with a header row (`running_costs_col_cargo`, `_items`, `_income`, `_per_item`, `_on_time`, `_capacity`), one row per `TI.rows` entry: `Component{ meta = { tooltip = name }, layout = BoxLayout{ children = { ImageView{ path = icon, class kampfmoehre-rc-cargo } } } }`, `n` (`kampfmoehre-rc-num`), `money(income)` (`positive, kampfmoehre-rc-money`), `perItem and money(perItem) or "–"`, `onTimeShare and string.format("%d %%", round(share × 100)) or "–"`, `capacity or "–"`; a sum row (`running_costs_sum`, `Σ n`, `money(sum.income)`). Footnote by mode: `running_costs_income_booked {amount}` (own), `running_costs_income_line_factor` (line), `running_costs_income_raw` (raw). Then the result line: `fmt("running_costs_result", { amount = money(result) })` with class `positive` (≥ 0) / `negative` (< 0), or `"–"` with tooltip `running_costs_income_raw` when `result == nil`.
  - `strings.json` EN (exact): `running_costs_income_header` "Income of the last {minutes} min of game time", `running_costs_col_cargo` "Cargo", `running_costs_col_items` "Items", `running_costs_col_income` "Income", `running_costs_col_per_item` "per item", `running_costs_col_on_time` "on time", `running_costs_col_capacity` "Capacity", `running_costs_income_booked` "booked by the game: {amount}", `running_costs_income_line_factor` "scaled with the line's bookings", `running_costs_income_raw` "base prices, before the company-level factor", `running_costs_result` "Result: {amount}", `running_costs_no_income` "no income yet", `running_costs_result_tooltip` "Income minus running costs of the window shown above."

- [ ] **Step 1: Write strings (EN + DE) and the two CSS rules.**
- [ ] **Step 2: Implement the reader, booked income, capacity, `tableData` extension and the rendering** as specified; `VERSION = "0.2.0"`.
- [ ] **Step 3: `luajit -bl` all GUI files; run the suite; grep `for _,` in GUI files (none); `./sync.sh`.**
- [ ] **Step 4: In-game check (user):** single-truck save: after a few deliveries the income table shows one row with icon, items, income, per item, on time, capacity 40; after a full window income ≈ the game's income bar for the span, footnote "booked by the game"; result line = income − cost sum. Vehicle window: same table; footnote tells whether the vehicle account or the line factor was used. Big save: the grain/fertiliser/meat line shows three rows sorted by income with capacities; a passenger line shows one "Passengers" row with "–" on time; no `error` lines; company balance trend unchanged (no price change); the income perf line within budget. Report what the footnotes said (own account readable or not).
- [ ] **Step 5: Report** files + `feat: income per cargo type and result line in the cost tables`.

---

### Task 5: Docs and release preparation

**Files:**
- Modify: `README.md` (section "Income per cargo type": what the rows mean, the scaling to booked income and its two fallbacks, passengers, that the vehicle must exist in the cost history for coverage), `CHANGELOG.md` (`## 0.2.0 (date)`), `mod.json` `revision` 3, `_metadata/modinfo.json` EN/DE (new paragraph + re-rendered changelog via `python3 -I ../changelog_to_modinfo.py tpf3-running-costs kampfmoehre_running_costs_1`), `/home/satan/dev/tpf3-modding/CLAUDE.md` mod table row (version, revision, one line on the income collector and the measured handler cost).

- [ ] **Step 1: Write the README section and the changelog entry; bump the revision; render the description.**
- [ ] **Step 2: `./sync.sh`; Mod-Hub "reload" for strings/modinfo (user).**
- [ ] **Step 3: Report** files + `docs: 0.2.0 income breakdown`. Gallery image of the income table is the user's.
