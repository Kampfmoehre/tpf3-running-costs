# Running Cost Breakdown — design

Date: 2026-10-20. Mod for Transport Fever 3 (build 40422), new sibling repo `tpf3-running-costs/`,
modId `kampfmoehre_running_costs_1`, log prefix `[kampfmoehre_running_costs]`. German title in the
description: "Betriebskosten aufgeschlüsselt". Conventions, paths, API notes and the measured cost
rule live in `../../../CLAUDE.md` of the parent directory; this document only adds what is specific
to this mod.

## Intent

When a line loses money, the player opens its window and sees one bar per period labelled
"Betriebskosten" (running costs). Nothing says where that money went: were the vehicles driving,
queueing at a signal or in front of a harbour, standing at a terminal, parked in a depot, or simply
worn out and therefore surcharged? The game applies different rates to these states (see below) but
never shows them, and the maintenance-state surcharge disappears in the finance window as soon as a
company has more than one vehicle.

The mod makes the game's own cost rule visible: per line a breakdown of the running costs of the last
default game year by vehicle state, per vehicle the same breakdown plus a live line with the rate the
vehicle costs right now and why. The player draws the conclusions (fewer vehicles, a cheaper or faster
model, faster terminals, a different route). The mod gives facts, never recommendations.

## The cost rule the mod displays (measured 2026-10-20)

The game books `MAINTENANCE/VEHICLE` every 60 s of game time, per default-year ticks
(`api.util.getDefaultYearDuration()` = 1461000 ms; the calendar speed setting does not change it).
`api.engine.util.vehicle.getRunningCost(v)` is the per-year value including the maintenance-state
surcharge. For one minute in a state the game charges `getRunningCost × 60 / 1461 × factor`:

| Vehicle state | factor | how to detect (`TRANSPORT_VEHICLE` component) |
|---|---|---|
| driving | 1.00 | `state == EN_ROUTE` or `GOING_TO_DEPOT`, speed ≥ 0.5 m/s |
| waiting en route (signal, traffic, harbour queue) | 1.00 | `state == EN_ROUTE` or `GOING_TO_DEPOT`, speed < 0.5 m/s |
| user-stopped (`userStopped == true`, outside a depot) | 1.00 | counts as driving/waiting by speed; no own row |
| at a terminal (loading, unloading, dwell wait, "full load" wait) | 0.40 | `state == AT_TERMINAL` |
| in a depot | 0.05 | `state == IN_DEPOT` |

Maintenance-state surcharge: `getRunningCost(v) − Σ parts' metadata.maintenance.runningCosts`
(the parts come from `transportVehicleConfig.vehicles[i].part.modelId` via `api.res.modelRep.get`).
The difference is 0 for a healthy vehicle and grows as the state drops (+7.5 % at "Mittelmässig",
+23 % at "Sehr schlecht"). `transportVehicle.maintenanceFactor` is ignored by the game and by the mod.

## Goals

1. Line window: under the income graph in the "Ertrag" card, a table "Running costs of the last
   24 min of game time" with the rows driving, waiting en route, at terminal (40 %), in depot (5 %),
   maintenance surcharge (+x %), and a sum row. Each row shows the time share as a bar and the amount.
2. Vehicle window: a live line under "Grundlagen" — "Costs now €X/min · <state>, <factor> ·
   condition +y %" — coloured by rate (reduced rate green, waiting en route orange, driving neutral),
   expandable to the same table for this vehicle.
3. The time window is one default game year (1461 s of game time), rolling, saved with the game.
4. Zero influence on the simulation: `cosmetic: true`, no commands, no bookings.
5. English and German texts (`strings.json`), money via `api.util.formatMoney`.

## Non-goals (this version)

- No recommendations ("too many vehicles", "use a cheaper model"); Line Profit Auditor and Vehicle
  Trip Statistics do that already and the player decided against it.
- No infrastructure or station costs; the game's "Betriebskosten" bar does not contain them either.
- No wait-time progress bar on the 3D preview (remaining min. dwell time). Planned for a later
  version; the fields exist (`timeUntilDeparture`, `timeUntilCloseDoors`).
- No per-vehicle rows inside the line table, no company-wide view, no mod params in version 1.
- No balancing. A separate, non-cosmetic mod may later book journal corrections; this mod should be
  able to show those corrections, but nothing is built for it now beyond keeping the rule in one
  module.

## Anti-goals

- A reset button or a "since last load" window: the player rejected both; numbers must not swing
  with reloads. Everything the tables show is reproducible from saved data.
- Frame-time cost noticeable in a 400-vehicle save. The vehicle store's cart re-renders every frame;
  nothing of this mod may run per frame except cheap state reads.
- Calling the window a "year": the length depends on the calendar-speed setting. Label it by game
  time ("last 24 min of game time") and explain in a tooltip that it equals one year at normal
  calendar speed.

## Constraints

- Everything in `CLAUDE.md` of the parent directory applies: repo layout, `sync.sh`, `VERSION`
  constant, log prefix, `strings.json` + `modinfo.json` `localization.de`, LLM disclaimer, EN/DE texts,
  `luajit -bl` syntax check, in-game verification by the user before any upload.
- Lua 5.1 / LuaJIT. Never `_` as a loop variable in GUI code. No `rawget`/`rawset` in the GUI state.
  `api.engine.getComponent(...)` returns plain tables (use `ipairs`).
- **Game scripts run on a pool of sim threads with separate Lua states.** `update()` of a game
  script is dispatched to any pool thread (14 on the author's 8-core/16-thread CPU; the count
  follows the CPU, so never assume a number); module locals are per thread. All data that must
  persist between updates lives in `state:get()/set()` (shared, saved with the game). Two threads can
  both see an empty state in the very first tick; make initialisation idempotent.
- Vehicle running costs are static per model and cannot be changed per vehicle; the mod only reads.
- `api.gui.byId.isVisible(id)` is false for pinned windows; use `react.onUnmount` for lifecycle.
- Collapsible cards in entity windows follow the `content_card.ContentCard` pattern (see CLAUDE.md,
  "Collapsible entity-window cards"); a `TableLayout` row has no border of its own.
- A plugin recipe must return a layout; `builtin.Component{ layout = X }` needs a layout, not a
  TextView (crashed Top Speed 0.5.0).

## Decided

### Data collection (engine side)

- A game script (`content/<dir>/<name>.gs.lua` + `.script.lua`, `updateScript`), found by extension,
  no `mod.json` entry. Pattern: the temporary probe in
  `tpf3-rate-preview/kampfmoehre_rate_preview_1/content/cost_probe/` (remove it there before the next
  upload of Rate Preview) and the base `loan.script.tl` / `vehicle_modifier.script.tl`.
- Sampling interval 2 s of game time (gameTime from the `GAME_TIME` component of the world entity,
  in ms). Per sample, for every vehicle of `api.engine.util.vehicle.getVehicles()`: classify the state
  per the table above, read `getRunningCost` and `getSpeed`, compute the parts' static cost sum
  (cache per model id in the state or recompute: the builder's call, see below).
- Accumulated per vehicle and per class: game seconds spent, and cost at the **static** rate
  = `static × dt / year × factor` (static = the parts' metadata `runningCosts` sum, i.e. the rate of
  a healthy vehicle). Plus one surcharge accumulator `(rc − static) × dt / year × factor` over all
  states. The four state rows therefore show what the vehicle would have cost in perfect condition,
  the surcharge row the extra the game charged for its condition, and the sum of the five rows is
  what the game books (`rc × dt / year × factor` summed). Every row is additive; the sum row is the
  figure to compare with the game's "Betriebskosten" bar. (My call, settled after the builder check.)
- Rolling window of 1461 s: ring buffer of buckets per vehicle (e.g. 24 buckets of ~61 s; exact
  count is the builder's). The table sums the buckets of the last 1461 s; while a vehicle has less
  than a full window of data (new vehicle, mod added to an old save) the header says
  "last N min of game time" with the actual coverage.
- Line table = sum over the vehicles currently on the line, each with its full available history
  (player's decision). Vehicles that left the line or were sold take their history with them; a
  fleet replaced through the store starts from zero (the new vehicles differ anyway). The header
  names the longest coverage among the line's vehicles ("last 24 min of game time") and, when
  vehicles differ, adds "n vehicles with less data" (tooltip lists coverage per vehicle). The sum
  therefore does not always correspond to one period; the time-share bars are per-vehicle-weighted
  and stay correct.
- Entities that disappear are dropped from the state on the next sample. State size target: a few
  hundred bytes per vehicle.

### Transport to the GUI

The vehicle and line windows read the accumulated data on the GUI thread. Left to the builder which
mechanism: a `guiUpdateScript` in the same game script (runs on the GUI thread, gets the state
read-only, can store the table in a module field of `builtin` for the plugins to read, see
CLAUDE.md "share state between our mods"), or `api.res.gameScriptRep`/`getEntityForGameScript`
reads from the plugin. The GUI must never block on the engine; a one-sample lag is fine.

### Presentation

- Line window: the table sits inside the "Ertrag" card under the income graph (variant B in the
  brainstorm). The base card (`LineIncomeGraphPlugin`, order 60, `meta.localKey = "lineBalance"`) has
  no child slot, so this is done by wrapping the shared module function `content_card.ContentCard`
  (the technique Window Placement uses on `builtin.Window`: forward all arguments, act only when
  `localKey == "lineBalance"`, replace `recipeAndParamPermanent` with a recipe that renders the
  original graph plus our table). My call: the wrap is acceptable, it is the same class of hook the
  other mods already ship, and it must be a no-op for every other card. Fallback only if the wrap
  proves fragile in game: an own `::LineEowExtensionPoint` card at order 61 directly below "Ertrag"
  with the same heading; note the fallback in the README if used.
- Vehicle window: `::VehicleEowExtensionPoint` plugin, order after Top Speed's row (Top Speed uses
  15 in the vehicle and 25 in the line window). Live line text pattern:
  `Costs now {rate}/min · {state}, {factor} · condition +{surcharge} %`; the surcharge part is
  omitted at 0 %. Colours: terminal and depot = class `success` (green), waiting en route = a warning
  colour defined in the mod's `*.css.lua`, driving = default. The live line is computed in the GUI
  from the component and `getRunningCost` on each render (`useStepState`-style, as the vehicle
  window's own widgets do), not from the sampler.
- Expanded table (vehicle) and the line table share one recipe and are **table-driven**: the cost
  classes live in one Lua module as an ordered list of `{ key, factor, labelKey, colour }` plus a
  classify function; the sampler accumulates per key, the GUI renders one row per key that has data.
  Version 2 will add speed buckets (e.g. "driving < 50 % of top speed", "50-90 %", "≥ 90 %") and the
  balancing mod's corrections as further classes, so no row may be hard-coded in the GUI and the
  saved accumulators must tolerate unknown or added keys. Rows with zero time in the window are
  hidden except the sum (my call: most players sell idle vehicles instead of parking them, so the
  depot row would usually be an empty line). Columns: label, time-share bar, amount. The factor stands in the label: "At terminal (40 %)", "In depot (5 %)", "Condition
  surcharge (+6 %)"; driving and waiting carry no factor. Bars are proportional to the time share of
  the window; the surcharge row has no bar. A sum row closes the table. A footnote shows the window
  ("last 24 min of game time", tooltip: equals one year at normal calendar speed, two at 0.5×) and,
  if the per-vehicle account can be read with `api.engine.util.finance.calculateBalance({vehicle},
  t0, t1, true, Maintenance.VEHICLE)`, the booked amount for the same window as a cross-check
  ("booked: €3.75 M"). If that API does not work for vehicle entities, drop the cross-check silently.
- Mod params: none in version 1.

### Repo

`tpf3-running-costs/` with `kampfmoehre_running_costs_1/` (mod.json cosmetic, strings.json,
`_metadata/modinfo.json` + images, `content/gui/kampfmoehre_running_costs/` for the GUI scripts,
`content/running_costs/` for the game script), `sync.sh`, README.md, CHANGELOG.md, LICENSE MIT,
`.gitignore`. Version `0.1.0`, `revision` 1.

## Left to the builder

- Exact state layout and bucket count; whether the static per-model cost is cached in the state or
  recomputed from `modelRep` (cheap, the model table is in memory).
- The GUI transport mechanism (see above).
- Whether the sampler runs every update and skips by time, or subscribes to nothing and polls; the
  probe shows `update` is called every 0.2 s of game time.
- How the expanded vehicle table is toggled (the collapsible-card pattern or a chevron in the live
  line).
- Unit tests: the classification and accumulation functions should be pure Lua, testable with
  `luajit` like Rate Preview's `test/`.
- Performance measurement with `api.type.Clock` in the sampler during the in-game check (target:
  well under 1 ms per sample for 400 vehicles; the probe did the same work plus logging without a
  visible effect).

## Verification

The player tests in game before upload (CLAUDE.md). Acceptance: on the 364-vehicle save
("Sävsjö Schiensen") the line table of a cargo line sums to roughly the "Betriebskosten" bar of the
same period once a full window has elapsed; the single-truck test save (seed `MqUHIqHlPq`) shows a
pure-driving window at 100 %, a dwell-wait window at 40 %, a depot window at 5 %; no "Global
variable in mod" or error lines in `stdout.txt`; FPS unchanged with the line window open.

## Later versions (not designed here)

Wait-time bar on the 3D preview; rolling average for the window's own "Ertrag" figure; per-vehicle
rows in the line table; a shared base mod for the samplers; the balancing mod that books journal
corrections for speed-dependent costs and shows them in this table.
