# Income Breakdown (Running Cost Breakdown 0.2.0) — design

Date: 2026-10-21. Second feature of the mod `kampfmoehre_running_costs_1` (repo `tpf3-running-costs/`).
Builds on the shipped 0.1.x: the game script sampler, the per-vehicle ring buffer
(`cost_history.lua`), the table recipe in vehicle and line windows and the Balance-card wrap.
Read `2026-10-20-running-cost-breakdown-design.md` first; conventions in `../../../CLAUDE.md`.

## Intent

The cost table answers "where can I save?". The player's next question when a line loses money
is "what do I actually earn with?": a cargo line that carries grain, fertiliser and meat shows one
income bar. Whether a second train just for meat would pay, or whether specialised wagons (more
capacity per cargo, but a fixed maximum per cargo) beat mixed ones, needs the income per cargo type
next to the capacity the consist offers for it. The game has the data per delivered item but shows
only the total.

## Mechanics (from the sources)

- `cargo_income.script.lua`: income per item = `incomeFactor × difficultyFactor × travelDistance`,
  passengers additionally `× (0.5 + vehiclePriceFactor)`; `travelDistance` is the straight 3D
  distance plus 8 × the positive height difference. `incomeFactor`, `priceFactor` come from C++.
- Every paid item raises the game-script event **`OnCalcTicketPrice`**, batched as an array of
  events: `id == "TransportVehicleSystem"` for cargo (`CalcTicketPriceCargoEvent`: `vehicleEntity`,
  `lineEntity`, `simEntity`, `stockListEntity`, `basePrice`, `distance`), `id ==
  "SimEntityAtVehicleSystem"` for passengers (`CalcTicketPriceEvent`: same without `stockListEntity`).
  The cargo type is `api.engine.getComponent(simEntity, SIM_CARGO).cargoType`;
  `api.engine.util.cargo.isGoodQuality(simEntity)` tells whether the item was on time. Base scripts
  (`towns.script.tl:401`, `town_growth.script.tl:620`, `company_growth.script.tl:159`,
  `deliver_cargo.script.tl:456`) consume it the same way; a handler that returns nothing changes no
  price. A handler that returns `{ [i] = multiplier }` would, so this mod's handler returns nothing.
- `basePrice × distance` is not the booked amount: `company_growth` returns a global multiplier
  (ticket price per company level), subventions double single items. The booked income of a line
  or vehicle over a period comes from its account (`api.engine.util.finance.calculateBalance({entity},
  t0, t1, true)` = maintenance + income entries; income alone = that minus the maintenance types
  `VEHICLE`, `VEHICLE_MAINTENANCE`, `INFRASTRUCTURE`, `OTHER` queried one by one, or an income-only
  variant if one works — builder verifies in game).
- The per-cargo capacity the vehicle window shows ("0/40") is `TRANSPORT_VEHICLE.config
  .capacities[cargoTypeId + 1]`; passengers are the cargo type
  `api.res.cargoTypeRep.getPassengerCargoTypeId()`.

## Goals

1. A second table under the cost table, in the line window (inside the Balance card) and in the
   vehicle window (same collapsible), headed "Income of the last N min of game time" with one row
   per cargo type that earned anything in the window (passengers are one row), columns: cargo icon
   and name, items delivered, income, income per item, on-time share, capacity of the consist(s)
   for that cargo. A sum row (items, income). Rows ordered by income, descending.
2. Under both tables one line **Result: income − running costs of the window**, coloured like the
   game colours money (positive blue, negative red).
3. Amounts are the event base values `basePrice × distance`, scaled per table so that their sum
   equals the booked income of the same window. Line table: the line's account. Vehicle table: the
   vehicle's account if `calculateBalance({vehicle}, …)` yields a number, otherwise the **line's
   factor** (booked line income ÷ Σ base of the line's vehicles over the window) applied to the
   vehicle's base values (my call after the builder check: the company-level multiplier is uniform,
   so the line's factor is the right one for every vehicle on it). The footnote says "booked by the
   game: €X" (own account) or "scaled with the line's bookings" (line factor). Only if neither
   account can be read are raw base values shown with the footnote "base prices, before the
   company-level factor", and then the result line (goal 2) is replaced by "–" with that footnote as
   tooltip: a result from pre-multiplier prices is not a result.
4. Same rolling window, coverage header, "n vehicles with less data", hidden empty rows and
   replaced-vehicle semantics as the cost table; the two tables share one coverage header when
   their coverage is identical (it is: both come from the same per-vehicle histories' `first`).
5. Zero influence on prices: the event handler never returns a value.

## Non-goals

- No profit per cargo type and no allocation of costs to cargo types (an arbitrary key; the player
  does the comparison with the capacity column).
- No boarding/alighting per stop for passengers (line planning, not costs; Vehicle Trip Statistics
  covers the direction).
- No change to the cost table beyond the shared header and the result line.
- No income breakdown for lines without vehicles, no company-wide view, no mod params.

## Anti-goals

- Returning anything from the `OnCalcTicketPrice` handler (would change prices, breaks cosmetic).
- Rows swinging with reloads (the data lives in the saved state like the costs).
- A visibly slower sampler: the event handler does O(items) work per batch and no engine queries
  besides `SIM_CARGO` + `isGoodQuality` per item; capacities are read on the GUI side when a window
  is open, not in the sampler.

## Decided

### Data collection (engine side, a second game script)

Settled after the builder check (my call): the cost sampler's state is large (one `get`/`set`
costs ~2.5 ms each at 364 vehicles, independent of the exact size, see the 0.1.1 perf lines), and
every `OnCalcTicketPrice` batch would pay that twice. The income therefore lives in **its own game
script with its own, small state**, `content/running_costs/income.gs.lua` +
`income.script.lua`, registered with `handleEventScript` only (no `updateScript`):

- Subscription: a game script without `update` cannot subscribe lazily, so the subscription is made
  in `handleEvent` on the lifecycle events the base uses (`id == ""`, `name == "initNewGame"` /
  `"initNewGameFromMap"` / `"handleLegacy"` / `"load"`, see `company_growth.script.tl:117-121` and
  `vehicle_modifier.script.tl`); the builder verifies in game which of them a script added to an
  existing save receives, and falls back to subscribing from the cost sampler's `update` only if
  none does (then the cost script would need a tiny `handleEvent` that forwards nothing; avoid).
- `handleEvent(userParams, state, src, id, name, param)`: only `name == "OnCalcTicketPrice"`;
  `id == "TransportVehicleSystem"` → cargo batch, `id == "SimEntityAtVehicleSystem"` → passenger
  batch. Passengers are an ordinary cargo type: `api.res.cargoTypeRep.getPassengerCargoTypeId()`.
  Per event: `v = vehicleEntity`, `key = SIM_CARGO.cargoType` (passenger id for the passenger
  batch), `base = basePrice × distance`, `ok = api.engine.util.cargo.isGoodQuality(simEntity)`
  (try for passengers too; if it throws or returns nil, store nothing for them).
- State: `{ version, batches, items, v = { [vehicle] = { head, b = { [slot] = { t0, inc = { [key] =
  { n, base, ok } } } } } } }` — the same ring geometry as `cost_history` (7 × 243 500 ms, `t0` on the
  same grid) but **no `first` and no time accumulation**: coverage, the window cut and the pro-rata
  weight of the oldest bucket are taken from the vehicle's **cost history** (`summary.cov` and the
  cost buckets' `first`), because "no deliveries since the vehicle exists" is real information and
  both tables must share one header and one result line. `cost_history.lua` gets the bucket ring
  factored so both scripts use it (`M.bucketFor` / `M.weights(h, nowMs, windowMs, first)` returning
  the per-slot weights), and `M.windowIncome(ih, nowMs, windowMs, first) → { [key] = { n, base, ok } }`.
- Per batch: `state:get()` → add all items → `state:set()`. Every 50th batch the handler drops
  vehicles that no longer exist (`api.engine.entityExists`). Budget: ≤ 1 ms of one pool thread per
  second of game time on the 364-vehicle save; the handler measures itself with `api.type.Clock`
  and the cost sampler's perf line is joined by one for the income script every 300 s of game time
  (batches, items, ms per batch). If the budget is exceeded, the builder reports before optimising.
- The handler never returns a value.
- Threading: `handleEvent` of this script and `update` of the cost script touch different states,
  so they cannot lose each other's writes. Two batches of the same script interleaving on two pool
  threads would lose one batch's items; the builder adds a `batches` counter to the state and a
  module-local count per thread, logs once if the state's counter ever runs ahead of the sum of
  what this thread wrote plus what it read, and the plan treats a confirmed interleave as a bug to
  design against (serialising through `update` of the cost script), not as acceptable loss.
- The cost sampler stays as it is (STATE_VERSION 2); the income script has its own
  `INCOME_STATE_VERSION 1`.

### Presentation (GUI)

- `cost_rows.lua` gets `M.buildIncome(summaries, cargoNames, bookedIncome | nil) → { rows = { {
  key, n, base, income, perItem, onTimeShare | nil } }, sum = { n, income }, scaled = boolean,
  empty }` where `income = base × (bookedIncome / Σ base)` when `bookedIncome` is a number and
  `Σ base > 0`, else `income = base`; rows sorted by `income` desc; a row needs `n > 0`.
- Capacity per cargo of a consist: GUI side from `config.capacities`; the line's capacity is the
  sum over its vehicles. Shown as an integer in the last column, "–" when the consist cannot carry
  the cargo (income from before a refit).
- Cargo name and icon: `api.res.cargoTypeRep.get(id)` (`name`, `icon`); passengers use the game's
  passenger icon. Icon as `builtin.ImageView`, name in the tooltip of the row.
- The income table sits directly under the cost table in the same `CostTable` recipe (one recipe,
  two tables, one header, one result line). Column weights `{ -1, -1, -1, -1, -1, -1 }` with the
  cargo cell left and all numbers right-aligned (`kampfmoehre-rc-money` for money, a new
  `kampfmoehre-rc-num` for counts). Rows fit the window at the user's UI scale; if six columns do
  not fit at "large" font, the builder drops "income per item" into the row tooltip.
- Result line: `Result: €X` using the game's classes `positive` (≥ 0) / `negative` (< 0), computed
  from the two tables' sums (income scaled or raw, costs as shown).
- Texts (EN; DE by the builder, the user reviews): `running_costs_income_header` "Income of the
  last {minutes} min of game time", `running_costs_col_cargo` "Cargo", `running_costs_col_items`
  "Items", `running_costs_col_income` "Income", `running_costs_col_per_item` "per item",
  `running_costs_col_on_time` "on time", `running_costs_col_capacity` "Capacity",
  `running_costs_income_booked` "booked by the game: {amount}", `running_costs_income_raw` "base
  prices, before the company-level factor", `running_costs_result` "Result: {amount}",
  `running_costs_passengers` "Passengers", `running_costs_no_income` "no income yet".
- Version 0.2.0, revision 3, CHANGELOG, README (new section "Income per cargo"), modinfo EN/DE.
- The result line and the income table use the cost table's coverage; a vehicle with cost coverage
  but no deliveries shows the income table with the single line "no income yet" and a result equal
  to minus the costs.

## Left to the builder

- Exact bucket field layout for `inc`; the GUI reads the vehicle's income ring with one
  `findPath({"v", vehicle})` on the income script's state and the cost summary as today.
- How income-only booking is read from an account (see Mechanics); verified in game with the
  single-truck save: the scaled income of its one cargo must equal the booked income.
- Capacity per cargo: `TRANSPORT_VEHICLE.config.capacities[cargoTypeId + 1]` (what the vehicle
  window's "0/40" uses); the line's capacity is the sum over its vehicles.
- Tests (luajit): `addIncome`/`window` income sums with pro-rata, `buildIncome` scaling, sorting,
  raw fallback, on-time share with nil, result sign.
- Perf of the event handler (get/set per batch) on the 364-vehicle save; the fallback queue only
  if needed.

## Verification

Single-truck save: after a full window the income table shows one row, items = deliveries counted
in the line's "Transportiert", income within a few % of the booked income; the result line equals
income − cost sum. Big save: the grain/fertiliser/meat line shows three rows with sensible
capacities; the vehicle window of one of its trains shows the same cargos; no `error` lines,
no price changes (company balance trend unchanged); the perf line shows the handler cost.
