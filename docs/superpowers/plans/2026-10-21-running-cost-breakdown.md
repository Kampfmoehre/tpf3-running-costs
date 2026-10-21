# Running Cost Breakdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A cosmetic TF3 mod that shows, per vehicle and per line, how the game's running costs of the last default game year split by vehicle state (driving, waiting en route, at terminal 40 %, in depot 5 %) plus the maintenance-state surcharge, and a live "costs now" line in the vehicle window.

**Architecture:** A game script (engine thread, state saved with the game) samples every vehicle every 2 s of game time, classifies its state and accumulates seconds and cost per class into a per-vehicle ring buffer of 13 buckets of 121 750 ms; it also keeps a compact per-vehicle window summary in the state. GUI plugins read that summary from the game-script component (`GAME_SCRIPT`), render the table in the vehicle window (collapsible under a live row) and inside the line window's "Balance" card (by wrapping `content_card.ContentCard`). Classification, ring buffer and row building are pure Lua modules with luajit tests; everything touching `api` lives in two thin scripts.

**Tech Stack:** Lua 5.1 / LuaJIT, TF3 react-like GUI (`::/gui/main/react.lua`, `builtin.lua`, `content_card.tl`), TF3 game scripts (`*.gs.lua`), luajit for tests. No external libraries.

**Spec:** `docs/superpowers/specs/2026-10-20-running-cost-breakdown-design.md` (this repo). Project conventions: `/home/satan/dev/tpf3-modding/CLAUDE.md`.

## Global Constraints

- modId `kampfmoehre_running_costs_1`, directory `tpf3-running-costs/`, log prefix `[kampfmoehre_running_costs]`, `local VERSION = "0.1.0"` logged on load of both scripts, `mod.json` `revision` 1, `cosmetic: true`, no params.
- **No commits by the implementer.** The user commits, pushes and uploads himself (CLAUDE.md). Every task ends by listing the changed files and a suggested conventional commit message instead of committing. `git init` of the new repo is part of Task 1.
- English texts in `strings.json` `en`, German in `de`; `modinfo.json` `name`/`summary` plain English, German under `localization.de`; description HTML with the LLM disclaimer sentence: "This mod was created with the help of LLMs but all code was reviewed and tested by me."
- Game scripts: `update()` runs on an arbitrary sim-pool thread with its own Lua state; everything persistent goes through `state:get()`/`state:set()`; initialisation must be idempotent. `ug_require "kampfmoehre_running_costs_1::/..."` works in engine-side scripts (Smart Lanes does it).
- GUI code: never `_` as a loop variable (use `__`), no `rawget`/`rawset`, no globals (the loader logs "Global variable in mod"), plugins return a layout, `builtin.Component{ layout = X }` needs a layout. Forward all arguments when wrapping a module function.
- Window = `api.util.getDefaultYearDuration()` ms (1 461 000) of game time; never the calendar. Rates per minute = `perYear × 60 / 1461`.
- Factors: driving 1.00, waiting en route 1.00 (speed < 0.5 m/s while `EN_ROUTE`/`GOING_TO_DEPOT`), at terminal 0.40 (`AT_TERMINAL`), in depot 0.05 (`IN_DEPOT`). User-stopped vehicles have no own class.
- Syntax check every Lua file with `luajit -bl <file>`; run `luajit test/<name>_test.lua` from the repo root. In-game checks are done by the user; a task that needs one ends with the exact things he should look at.

## Review Focus

- A vehicle whose consist is modified or replaced mid-window (new static cost, possibly new entity): the table must not mix the old rate into new buckets, and a replaced entity starts with empty coverage instead of an error. Test in Task 3 (`cost_history_test.lua`, "static changes between buckets") and Task 4 (sampler drops entities that no longer exist).
- A save that gets the mod added later, or a vehicle bought a minute ago: coverage below the window must show "last N min of game time" with the real N and never divide by zero. Test in Task 3 ("coverage of a young history") and Task 5 (`cost_rows_test.lua`, "header with partial coverage").
- A line whose vehicles have different coverage (one new vehicle next to old ones): the header names the longest coverage and "n vehicles with less data". Test in Task 5 ("mixed coverage").
- Saved state from an older mod version or with class keys the GUI does not know: the sampler resets on a version mismatch, the row builder ignores unknown keys. Tests in Task 3 ("unknown keys tolerated") and Task 4 (state version reset).
- The line window open while the game script has not sampled yet (fresh save, first 2 s, or the mod disabled for this save): the reader returns nil and the table shows "no data yet" instead of an empty card or an error. Test in Task 5 ("no summaries → no rows, header no data") and in-game check in Task 6.

---

## File structure

```
tpf3-running-costs/
  kampfmoehre_running_costs_1/
    mod.json, strings.json, _metadata/modinfo.json           (Task 1, texts Task 6/7)
    content/running_costs/cost_classes.lua                   pure: class list, classify, factors (Task 2)
    content/running_costs/cost_history.lua                   pure: per-vehicle ring buffer, window sums (Task 3)
    content/running_costs/running_costs.gs.lua               game-script registration (Task 4)
    content/running_costs/running_costs.script.lua           sampler: api → classes/history → state (Task 4)
    content/gui/kampfmoehre_running_costs/cost_rows.lua      pure: summaries → table rows, header, live line (Task 5)
    content/gui/kampfmoehre_running_costs/vehicle.res.lua    react-plugin ::VehicleEowExtensionPoint, order 18 (Task 6)
    content/gui/kampfmoehre_running_costs/running_costs.script.lua  GUI: reader, CostTable, VehiclePlugin, ContentCard wrap (Task 6)
    content/gui/kampfmoehre_running_costs/running_costs.css.lua     bar and colour classes (Task 6)
  test/cost_classes_test.lua, test/cost_history_test.lua, test/cost_rows_test.lua
  sync.sh, README.md, CHANGELOG.md, LICENSE, .gitignore
```

Pure modules take every game value as a parameter (year length, factors, strings keys) so luajit can load them with `package.path` like `tpf3-top-speed/test/section_rows_test.lua` does.

---

### Task 1: Repo scaffold

**Files:**
- Create: `tpf3-running-costs/kampfmoehre_running_costs_1/mod.json`, `strings.json` (empty `en`/`de` objects), `_metadata/modinfo.json`
- Create: `sync.sh` (copy of `tpf3-top-speed/sync.sh` with `MOD_ID="kampfmoehre_running_costs_1"`), `.gitignore` (copy), `LICENSE` (MIT, copy with year 2026), `README.md` and `CHANGELOG.md` stubs

**Interfaces:**
- Produces: the mod directory the game loads from the staging area; `./sync.sh` works.

- [ ] **Step 1: Write `mod.json`** — same shape as `tpf3-top-speed/kampfmoehre_top_speed_1/mod.json` with `modId = "kampfmoehre_running_costs_1"`, `cosmetic = true`, `params = []`, `revision = 1`, empty run scripts.
- [ ] **Step 2: Write `_metadata/modinfo.json`** — `name` "Running Cost Breakdown", `summary` "Where a vehicle's or line's running costs come from: driving, waiting, at terminal, in depot, condition", `tags` `["Script Mod"]`, authors Kampfmoehre, `description` placeholder `<p>…</p>` (final text in Task 7), `localization.de.name` "Betriebskosten aufgeschlüsselt", `localization.de.summary` "Woher die Betriebskosten eines Fahrzeugs oder einer Linie kommen: Fahrt, Warten, Terminal, Depot, Zustand".
- [ ] **Step 3: Copy `sync.sh`, `.gitignore`, `LICENSE`; write README.md with only the title line and CHANGELOG.md with `# Changelog` and `## 0.1.0 (unreleased)`.**
- [ ] **Step 4: `git init` in `tpf3-running-costs/`** (no commit). Run `./sync.sh`.
  Expected: `synced -> …/staging_area/kampfmoehre_running_costs_1`.
- [ ] **Step 5: Report** the file list and suggested message `chore: scaffold Running Cost Breakdown mod`.

---

### Task 2: Cost classes (pure module)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/running_costs/cost_classes.lua`
- Test: `test/cost_classes_test.lua`

**Interfaces:**
- Produces:
  - `M.CLASSES` — ordered array of `{ key = string, factor = number, labelKey = string, colour = "default"|"ok"|"warn"|"off" }` with exactly these entries in this order: `driving` 1.0 `running_costs_class_driving` default; `waiting` 1.0 `running_costs_class_waiting` warn; `terminal` 0.4 `running_costs_class_terminal` ok; `depot` 0.05 `running_costs_class_depot` off.
  - `M.SURCHARGE_KEY = "surcharge"` (not a class; own row in the GUI, label key `running_costs_class_surcharge`).
  - `M.classify(stateName : string, speedMps : number, standingSpeed? : number) : string` — `stateName` is one of `"IN_DEPOT"|"EN_ROUTE"|"AT_TERMINAL"|"GOING_TO_DEPOT"` (anything else → `"driving"`); `standingSpeed` defaults to 0.5.
  - `M.factor(key : string) : number` — 1.0 for unknown keys.
  - `M.byKey : { [key] = class }`.

- [ ] **Step 1: Write the failing test** `test/cost_classes_test.lua` in the style of `tpf3-top-speed/test/section_rows_test.lua` (`package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path`, `check(name, cond)`, exit code 1 on failures):

```lua
check("order", M.CLASSES[1].key == "driving" and M.CLASSES[2].key == "waiting" and M.CLASSES[3].key == "terminal" and M.CLASSES[4].key == "depot")
check("factors", M.factor("terminal") == 0.4 and M.factor("depot") == 0.05 and M.factor("driving") == 1 and M.factor("nonsense") == 1)
check("depot", M.classify("IN_DEPOT", 0) == "depot")
check("terminal", M.classify("AT_TERMINAL", 0) == "terminal")
check("en route moving", M.classify("EN_ROUTE", 8.3) == "driving")
check("en route standing", M.classify("EN_ROUTE", 0.1) == "waiting")
check("going to depot standing", M.classify("GOING_TO_DEPOT", 0) == "waiting")
check("standing threshold is a parameter", M.classify("EN_ROUTE", 0.8, 1.0) == "waiting")
check("unknown state is driving", M.classify("state_7", 0) == "driving")
check("colour of waiting", M.byKey.waiting.colour == "warn")
```

- [ ] **Step 2: Run `luajit test/cost_classes_test.lua`** — Expected: FAIL (module not found).
- [ ] **Step 3: Implement `cost_classes.lua`** returning `M` as specified; no `api`, no `_()`.
- [ ] **Step 4: Run the test** — Expected: all `ok`, exit 0. `luajit -bl` the module.
- [ ] **Step 5: Report** files + `feat: cost classes and factors`.

---

### Task 3: Per-vehicle history (pure module)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/running_costs/cost_history.lua`
- Test: `test/cost_history_test.lua`

**Interfaces:**
- Consumes: nothing (class keys are opaque strings).
- Produces:
  - `M.BUCKET_MS = 121750`, `M.BUCKETS = 13` (12 cover 1 461 000 ms, one spare so a full window is always inside the ring).
  - `M.new(nowMs : number) : History` — `History = { start = bucketStartMs of the first bucket, head = index 1..BUCKETS, b = { [i] = Bucket } }`, `Bucket = { t0 = startMs, t = { [key] = seconds }, c = { [key] = cost }, s = surchargeCost }`.
  - `M.add(h : History, nowMs, dtMs, key : string, costPerYearStatic : number, surchargePerYear : number, factor : number, yearMs : number)` — adds `dtMs/1000` to `t[key]`, `costPerYearStatic × dtMs / yearMs × factor` to `c[key]`, `surchargePerYear × dtMs / yearMs × factor` to `s` of the bucket that contains `nowMs`; opens new buckets (dropping the oldest) as time advances; a jump backwards in time (`nowMs < h.start`) resets the history.
  - `M.window(h : History, nowMs, windowMs) : Summary` — `Summary = { cov = coveredMs (≤ windowMs), t = { [key] = seconds }, c = { [key] = cost }, s = surcharge, total = Σ c + s }` over the buckets whose `t0 + BUCKET_MS > nowMs − windowMs`; `cov = min(windowMs, nowMs − oldest counted t0)`, 0 for an empty history.
  - All functions tolerate keys they have never seen and buckets missing `t`/`c`/`s` (older saves): treat as 0.

- [ ] **Step 1: Write the failing test** `test/cost_history_test.lua` (`near(name, got, want, tol)` helper like `tpf3-rate-preview/test/rate_model_test.lua`):

```lua
local Y = 1461000
local h = M.new(0)
M.add(h, 2000, 2000, "driving", 1461000, 0, 1.0, Y)    -- 2 s at 1 461 000/yr = 2000 cost
local w = M.window(h, 2000, Y)
near("cost of 2 s driving", w.c.driving, 2000, 1e-6)
near("seconds", w.t.driving, 2, 1e-9)
near("coverage of a young history", w.cov, 2000, 1e-9)
M.add(h, 4000, 2000, "terminal", 1461000, 292200, 0.4, Y) -- 20 % surcharge at factor 0.4
near("terminal cost", M.window(h, 4000, Y).c.terminal, 800, 1e-6)
near("surcharge", M.window(h, 4000, Y).s, 160, 1e-6)
near("total", M.window(h, 4000, Y).total, 2960, 1e-6)
-- static changes between buckets: the new bucket uses the new rate
local h2 = M.new(0)
M.add(h2, 1000, 1000, "driving", 1000 * Y / 1000, 0, 1.0, Y)              -- 1 s at 1000/s → 1000
M.add(h2, M.BUCKET_MS + 1000, 1000, "driving", 2000 * Y / 1000, 0, 1.0, Y) -- 1 s at 2000/s → 2000
near("static change", M.window(h2, M.BUCKET_MS + 1000, Y).c.driving, 3000, 1e-6)
-- rollover: 14 buckets written, the ring keeps 13; the window = 12 full buckets
-- plus the partially covered oldest one, so bucket 0 is gone, 1..13 count
local h3 = M.new(0)
for i = 0, 13 do M.add(h3, i * M.BUCKET_MS + 10, 1000, "driving", Y, 0, 1.0, Y) end
local w3 = M.window(h3, 13 * M.BUCKET_MS + 10, Y)
near("window keeps 13 buckets, drops the 14th-oldest", w3.c.driving, 13 * 1000, 1e-6)
near("coverage capped at the window", w3.cov, Y, 1e-9)
-- unknown keys and sparse buckets tolerated
local h4 = M.new(0); M.add(h4, 500, 500, "speed_bucket_90", Y, 0, 1.0, Y)
h4.b[h4.head].c = nil
check("unknown key, missing c", M.window(h4, 500, Y).t.speed_bucket_90 == 0.5 and M.window(h4, 500, Y).total == 0)
-- time jump backwards (before the history's first bucket) resets
local h5 = M.new(500000); M.add(h5, 500500, 500, "terminal", Y, 0, 0.4, Y)
M.add(h5, 100, 100, "driving", Y, 0, 1.0, Y)
check("reset on backwards time", M.window(h5, 100, Y).t.terminal == nil and M.window(h5, 100, Y).t.driving == 0.1)
```

- [ ] **Step 2: Run `luajit test/cost_history_test.lua`** — Expected: FAIL.
- [ ] **Step 3: Implement `cost_history.lua`** per the interface. Bucket index for `nowMs`: `math.floor((nowMs − h.start) / BUCKET_MS)` relative to the first bucket; advance `head` and reuse the oldest table when the index moves past the ring (clear its `t`/`c`/`s`, set `t0`).
- [ ] **Step 4: Run the test** — Expected: all `ok`. `luajit -bl`.
- [ ] **Step 5: Report** files + `feat: per-vehicle cost history ring buffer`.

---

### Task 4: Game-script sampler

**Files:**
- Create: `kampfmoehre_running_costs_1/content/running_costs/running_costs.gs.lua`
- Create: `kampfmoehre_running_costs_1/content/running_costs/running_costs.script.lua`
- Reference: `tpf3-rate-preview/kampfmoehre_rate_preview_1/content/cost_probe/cost_probe.script.lua` (classification, state use, log helper that captures the global `log` before shadowing it), `game-src/game_mechanics/game_mechanics/finance/loan.script.tl`.

**Interfaces:**
- Consumes: `cost_classes` (`classify`, `factor`), `cost_history` (`new`, `add`, `window`, `BUCKET_MS`).
- Produces the saved state (read by Task 6):

```lua
state = {
  version = 1,                 -- STATE_VERSION; mismatch → state rebuilt from scratch
  tSample = gameTimeMs,        -- last sample
  tStart  = gameTimeMs,        -- first sample of this state
  v = { [vehicleEntity] = History },                -- cost_history tables
  summary = { [vehicleEntity] = Summary + { line = lineEntity, rc = perYearNow, static = perYearStatic } },
  perf = { lastMs = number, maxMs = number },        -- wall-clock cost of the last / slowest sample
}
```

- Game-script resource name as seen by `api.engine.system.gameScriptSystem.getEntityForGameScript`: `"kampfmoehre_running_costs_1::/running_costs/running_costs.gs"` (the pattern Smart Lanes documents, `square_smart_lanes::/smart_lanes/sl_lanes.gs`). Task 6 also falls back to scanning `api.res.gameScriptRep.getAll(true)` for a name containing `running_costs`.

- [ ] **Step 1: Write `running_costs.gs.lua`** — `data()` returning `{ updateScript = { fileName = "running_costs.script@update" } }` (relative to its folder, like the probe).
- [ ] **Step 2: Write `running_costs.script.lua`** with `function data() return { update = update } end` and:
  - `local VERSION = "0.1.0"`, `STATE_VERSION = 1`, `SAMPLE_MS = 2000`, `local gameLog = log` + `log(text)` helper (prefix), errors through `pcall` (log at most 10).
  - `staticPerYear(tv) : number` — Σ over `tv.transportVehicleConfig.vehicles[i].part.modelId` of `api.res.modelRep.get(id).metadata.maintenance.runningCosts`, cached per model id in a module-local table (per thread, fine).
  - `sample(state, nowMs)`: `yearMs = api.util.getDefaultYearDuration()`; for every `v` in `api.engine.util.vehicle.getVehicles()` with a `TRANSPORT_VEHICLE` component: `key = cost_classes.classify(stateName(tv.state), api.engine.util.vehicle.getSpeed(v) or 0)`, `rc = api.engine.util.vehicle.getRunningCost(v) or 0`, `static = staticPerYear(tv)`, `cost_history.add(h, nowMs, dtMs, key, static, math.max(0, rc − static), cost_classes.factor(key), yearMs)`, then `summary[v] = cost_history.window(h, nowMs, yearMs)` plus `line = tv.line`, `rc`, `static`. Entities not seen this sample are removed from `v` and `summary`. Measure the sample with `api.type.Clock.new()` and store `perf`.
  - `update(userParams, state, dt)`: return at `dt == 0`; `s = state:get()`; rebuild when `type(s) ~= "table" or s.version ~= STATE_VERSION or s.tSample == nil or s.tSample > now` (log "state reset"); return unless `now − s.tSample ≥ SAMPLE_MS`; `dtMs = now − s.tSample` (cap at `cost_history.BUCKET_MS` after a long pause so one sample cannot fill more than one bucket); `sample`; `state:set(s)`. Log `"v0.1.0 sampler started"` once per state rebuild and `perf` every 300 s of game time.
- [ ] **Step 3: `luajit -bl` both files; `./sync.sh`.**
- [ ] **Step 4: In-game check (user):** load the single-truck save (seed `MqUHIqHlPq`) and the big save. In `stdout.txt`: exactly one "sampler started" per load, no `error` lines, `perf` lines with `lastMs` well under 1 ms (single truck) and under ~3 ms (364 vehicles). Ask the user for the perf numbers and paste them into the task report.
- [ ] **Step 5: Report** files + `feat: game-script sampler for running cost classes`.

---

### Task 5: Row builder (pure module)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/cost_rows.lua`
- Test: `test/cost_rows_test.lua`

**Interfaces:**
- Consumes: `cost_classes.CLASSES`, `cost_classes.SURCHARGE_KEY` (pass the module in as a parameter so luajit can load `cost_rows` without `ug_require`).
- Produces:
  - `M.build(summaries : {Summary}, classes : CostClasses, windowMs : number) : Table` where
    `Table = { rows = { { key, labelKey, factor, seconds, share (0..1 of Σ seconds), amount, colour } }, surcharge = { amount, pct } | nil, sum = number, coverageMs = number, lessData = integer, empty = boolean }`.
    Rows appear in `CLASSES` order, only for keys with `seconds > 0`; `surcharge.pct = 100 × Σ s / Σ c` (nil when Σ c is 0); `coverageMs = max(cov)`, `lessData = count of summaries with cov < coverageMs − BUCKET tolerance 2000 ms`; `empty = true` when `summaries` is empty or every `cov == 0`.
  - `M.live(rcPerYear, staticPerYear, key, classes) : { perMin = rcPerYear × 60 / 1461 × factor, factor, surchargePct = round(100 × (rc − static) / static) or 0, colour }`.
  - `M.minutes(coverageMs) : integer` — rounded minutes for the header ("24" for 1 461 000).

- [ ] **Step 1: Write the failing test** `test/cost_rows_test.lua` (`package.path` with both `content/gui/kampfmoehre_running_costs/?.lua` and `content/running_costs/?.lua`):

```lua
local C = require "cost_classes"
local Y = 1461000
local full = { cov = Y, t = { driving = 1000, terminal = 300, depot = 0 }, c = { driving = 100000, terminal = 12000, depot = 0 }, s = 5600, total = 117600 }
local young = { cov = 120000, t = { driving = 60 }, c = { driving = 6000 }, s = 0, total = 6000 }
local T = M.build({ full }, C, Y)
check("two visible rows (depot hidden at 0 s)", #T.rows == 2 and T.rows[1].key == "driving" and T.rows[2].key == "terminal")
near("share of terminal", T.rows[2].share, 300 / 1300, 1e-9)
near("sum includes surcharge", T.sum, 117600, 1e-6)
near("surcharge pct of class costs", T.surcharge.pct, 5.0, 1e-6)
check("header with full coverage", T.coverageMs == Y and T.lessData == 0 and M.minutes(T.coverageMs) == 24)
local T2 = M.build({ full, young }, C, Y)
check("mixed coverage", T2.coverageMs == Y and T2.lessData == 1)
near("mixed sum", T2.sum, 123600, 1e-6)
local T3 = M.build({ young }, C, Y)
check("header with partial coverage", M.minutes(T3.coverageMs) == 2 and T3.lessData == 0)
check("no summaries → empty", M.build({}, C, Y).empty == true and #M.build({}, C, Y).rows == 0)
check("unknown keys ignored", #M.build({ { cov = Y, t = { x = 5 }, c = { x = 5 }, s = 0, total = 5 } }, C, Y).rows == 0)
local L = M.live(618211, 537575, "terminal", C)
near("live per minute", L.perMin, 618211 * 60 / 1461 * 0.4, 1e-3)
check("live surcharge", L.surchargePct == 15 and L.colour == "ok")
check("live healthy", M.live(1000, 1000, "driving", C).surchargePct == 0)
check("live static 0 → 0 %", M.live(1000, 0, "driving", C).surchargePct == 0)
```

- [ ] **Step 2: Run `luajit test/cost_rows_test.lua`** — Expected: FAIL.
- [ ] **Step 3: Implement `cost_rows.lua`** per interface; no `api`, no `_()`.
- [ ] **Step 4: Run the test** — Expected: all `ok`. `luajit -bl`.
- [ ] **Step 5: Report** files + `feat: table rows and live line from cost summaries`.

---

### Task 6: GUI — vehicle window row, line card table, strings, CSS

**Files:**
- Create: `content/gui/kampfmoehre_running_costs/vehicle.res.lua` (`react-plugin ::VehicleEowExtensionPoint`, `filePath = "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/running_costs.script@VehiclePlugin"`, `order = 18`)
- Create: `content/gui/kampfmoehre_running_costs/running_costs.script.lua`, `running_costs.css.lua`
- Modify: `strings.json` (all keys below, `en` + `de`)
- Reference: `tpf3-top-speed/.../top_speed.script.lua` (`makeRow`, `SectionsTable`, `VehiclePlugin`), `top_speed.css.lua` (ProgressBar classes), `game-src/gui/entity_window/line/line_eow.script.tl:658-690` (the card to wrap), `game-src/gui/main/content_card.tl:128` (how a card calls `recipeAndParam.recipe(param)`).

**Interfaces:**
- Consumes: `cost_classes`, `cost_rows`, the state layout of Task 4.
- Produces (inside the script's `data()`):
  - `readSummaries() : { [vehicleEntity] = Summary } | nil` — `getEntityForGameScript(GS_NAME)` (fallback: scan `api.res.gameScriptRep.getAll(true)` for `running_costs`), `api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT)`, then `gs.state.summary` (try `gs.state_native:find("summary")` first inside `pcall`, fall back to `gs.state and gs.state.summary`); cached per 2 s of game time in a module local; nil when the script is missing or has not sampled.
  - `CostTable = react.RegisterRecipe("KampfmoehreRunningCostsTable", function(p) … end)` with `p = { vehicles = {entity}, line = entity? }`: `react.onStepTimer(…, 2)` refreshes `cost_rows.build(summaries of p.vehicles, …)`; renders header TextView (`running_costs_header` with `{minutes}`, tooltip `running_costs_header_tooltip`; plus `running_costs_less_data` when `lessData > 0`, its tooltip listing `entity name: N min` per vehicle via `api.engine.util.getEntityName`), a `builtin.TableLayout{ columnWeights = { -1, 10, -1 } }` with one row per `rows` entry (label `_(labelKey)` formatted with `{factor}`/`{pct}` where the key has a placeholder, a `builtin.ProgressBar` with `value = share` and class `kampfmoehre-rc-bar` + colour class, amount `api.util.formatMoney(round)`), the surcharge row, the sum row, and the footnote `running_costs_booked` when `api.engine.util.finance.calculateBalance({ p.line or p.vehicles[1] }, now − coverageMs, now, true, api.type.JournalEntry.Maintenance.VEHICLE)` returns a number inside `pcall` (omit otherwise). `empty` → a single TextView `running_costs_no_data`.
  - `M.VehiclePlugin` — live row like Top Speed's `makeRow`: text `lang_util.format(_("running_costs_now"), { rate = formatMoney(perMin) })` .. " · " .. `_(class label)` .. (surcharge > 0 and " · " .. `running_costs_condition` or ""), class `success` for colour `ok`/`off`, `kampfmoehre-rc-warn` for `warn`; values from `cost_rows.live(getRunningCost(v), staticPerYear, classify(state, speed), classes)` recomputed in `react.onStepTimer(…, 1)`; collapsible part `content_card.makeRecipeAndParam(CostTable, { vehicles = { params.entityId } })` with `CARD_KEY = "kampfmoehreRunningCosts"`.
  - ContentCard wrap (installed once in `data()`): `local orig = content_card.ContentCard; content_card.ContentCard = function(...)` — read `params = select(select('#', ...), ...)`; when `type(params) == "table" and params.meta and params.meta.localKey == "lineBalance" and params.recipeAndParamPermanent` then replace `params.recipeAndParamPermanent` with `content_card.makeRecipeAndParam(BalanceWithCosts, { inner = original, line = original.param.entityId })`; always `return orig(...)`. `BalanceWithCosts` renders `builtin.BoxLayout{ orientation = Vertical, children = { p.inner.recipe(p.inner.param), CostTable{ vehicles = lineVehicles(p.line), line = p.line } } }` where `lineVehicles` = `api.engine.system.transportVehicleSystem.getLineVehicles(line)` in `pcall`. Guard against double wrapping across reloads: the GUI Lua state is rebuilt per load, so a plain module-local flag is enough.
  - `strings.json` keys (EN copy exact; DE by the implementer, the user reviews): `running_costs_now` "Costs now {rate}/min", `running_costs_class_driving` "driving", `running_costs_class_waiting` "waiting en route", `running_costs_class_terminal` "at terminal ({factor} %)", `running_costs_class_depot` "in depot ({factor} %)", `running_costs_class_surcharge` "condition surcharge (+{pct} %)", `running_costs_condition` "condition +{pct} %", `running_costs_header` "Running costs of the last {minutes} min of game time", `running_costs_header_tooltip` "One year at normal calendar speed (two calendar years at 0.5×, half a year at 2×). Sampled every 2 s of game time and saved with the game.", `running_costs_less_data` "{n} vehicles with less data", `running_costs_sum` "Sum", `running_costs_booked` "booked by the game: {amount}", `running_costs_no_data` "no data yet", `running_costs_vehicle_tooltip` "What this vehicle costs right now and why: the game charges 100 % while driving or waiting en route, 40 % at a terminal, 5 % in a depot, plus a surcharge for poor condition. Expand for the last {minutes} min.".
  - `running_costs.css.lua`: `R::KampfmoehreRunningCostsTable ProgressBar!kampfmoehre-rc-bar` like Top Speed's `kampfmoehre-ts-bar` (sizes per font class), `!kampfmoehre-rc-ok` → `colorDefault.Ok`, `!kampfmoehre-rc-warn` → `colorDefault.Warning`, `!kampfmoehre-rc-off` → `colorDefault.BaseLight` (or the nearest grey in `default_colors.gres`), `TextView!kampfmoehre-rc-warn` → `colorDefault.Warning`.

- [ ] **Step 1: Write `strings.json`** (en + de for every key above).
- [ ] **Step 2: Write `running_costs.css.lua`.**
- [ ] **Step 3: Write `running_costs.script.lua`** with `VERSION` logged on load, `readSummaries`, `CostTable`, `VehiclePlugin`, the ContentCard wrap and `BalanceWithCosts`; `vehicle.res.lua`.
- [ ] **Step 4: `luajit -bl` all three Lua files; run all three test files; `./sync.sh`.**
- [ ] **Step 5: In-game check (user), single-truck save:** vehicle window shows the live row under the basics card, coloured green at the terminal, orange when standing en route; expanding shows the table with driving/terminal rows and a sum; line window's "Balance" card shows the graph with the table under it; header says "last N min" with N growing to 24; the footnote "booked by the game" appears and is close to the sum once N = 24; `stdout.txt` has no `Global variable in mod` or error lines; closing and reopening windows does not duplicate the table. **Big save:** open 3 line windows and a vehicle window, FPS unchanged, a line with vehicles added recently shows "n vehicles with less data".
- [ ] **Step 6: Report** files, what the user confirmed, and `feat: running cost breakdown in vehicle and line windows`.

---

### Task 7: Docs and release preparation

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `_metadata/modinfo.json` (description EN/DE via `python3 -I ../changelog_to_modinfo.py tpf3-running-costs kampfmoehre_running_costs_1` after writing the base description), `strings.json` if the in-game check changed texts.
- Modify (other repo): delete `tpf3-rate-preview/kampfmoehre_rate_preview_1/content/cost_probe/` and run that repo's `./sync.sh` (the probe must not ship with the next Rate Preview upload).

- [ ] **Step 1: README.md** with the sections of `tpf3-top-speed/README.md` (title, what it shows, Installation, How it works — the measured cost rule table and the window definition, Development — tests and sync, License). State plainly that the table is cosmetic, that history starts when the mod is first active in a save, and that the line table sums each vehicle's own history.
- [ ] **Step 2: CHANGELOG.md** `## 0.1.0 (date of upload)` with one bullet per feature (live row, breakdown table in vehicle and line window, saved rolling window).
- [ ] **Step 3: modinfo description** EN (what, how to read it, the cost rule, cosmetic, disclaimer, changelog rendered by the script) and DE under `localization.de` opening with `<p><strong>Deutsch</strong></p>`.
- [ ] **Step 4: Remove the probe folder from Rate Preview and sync that repo.**
- [ ] **Step 5: `./sync.sh` here; Mod-Hub "reload" for strings/modinfo (user).** Report files + `docs: README, changelog and description for 0.1.0`. Gallery images (`_metadata/0.png`, 1920×1080) are the user's.
