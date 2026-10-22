# Running Cost Breakdown (Transport Fever 3)

A small UI mod for Transport Fever 3 that shows **where a vehicle's or a
line's running costs come from**. The game charges running costs at
different rates depending on what the vehicle is doing, but shows only one
"Running Costs" bar. This mod breaks that bar down:

| Vehicle state | Share of the running costs charged |
|---|---|
| driving (also standing in traffic or at a signal) | 100 % |
| stopped by the player, outside a depot | 100 % |
| at a terminal: loading, unloading, waiting for departure or a full load | 40 % |
| in a depot | 5 % |

On top of that the game adds a surcharge for poor condition (about +7 % at
"Fair", +23 % at "Very poor"), which is invisible in the finance window as
soon as a company has more than one vehicle.

What the mod adds:

- **Vehicle window:** a live line below the "Balance" card, `Now €X/min ·
  terminal 40 % · condition +12 %`, green while the vehicle runs at a
  reduced rate (terminal, depot), orange while it waits en route and pays
  the full rate. Expand it for a table of the last default game year:
  time share and cost per state, the condition surcharge, and the sum.
- **Line window:** the same table for all vehicles of the line, under the
  income graph in the "Balance" card. The sum is what the game booked; a
  footnote shows the booked amount from the line's account for comparison.
- Rows with no time in the window are hidden. Vehicles that joined the line
  later have a shorter history; the header then says "n vehicles with less
  data" and lists them in a tooltip.
- No recommendations: the mod shows facts, you draw the conclusions (fewer
  vehicles, a cheaper or faster model, faster terminals, a different route).
- Purely cosmetic, achievements stay enabled. English and German.

The time window is one **default game year** (1461 s of game time), the unit
the game itself books in. It does not follow the calendar speed setting: at
0.5× it spans two calendar years, at 2× half a year. The header therefore
says "last 24 min of game time" rather than "last year". The history is
recorded by the mod every 3 s of game time and saved with the game, so it
starts when the mod is first active in a save and survives reloads.

Available on mod.io: <https://mod.io/g/transportfever3/m/running-cost-breakdown>

## Income per cargo type (0.2.0)

Under the cost table a second table shows the **income of the same window
per cargo type**: items delivered, income, income per item, the share
delivered on time, and the capacity the consist(s) offer for that cargo.
Passengers are one row. Rows are sorted by income; a sum row and a
**Result** line (income minus running costs of the window) close the block.

Where the numbers come from: the game raises an event for every paid item
with its base income (`basePrice`, the whole amount before the company-level
factor; the event's `vehicleEntity` field repeats the item, so the vehicle
is taken from the item's `SIM_ENTITY_AT_VEHICLE` component); the mod counts
them per vehicle and cargo type in the same time buckets as the costs. The base
values are not what the game books (the company level scales ticket prices,
subventions double single items), so the table scales them to the income
booked on the line's account in the same window; the footnote shows that
amount. For a single vehicle the vehicle's own account is used when the
game provides one, otherwise the line's factor ("scaled with the line's
bookings"). Only when no account is readable are base prices shown and the
Result line is replaced by "–".

The income table uses the cost table's coverage: a vehicle that exists but
delivered nothing shows "no income yet" and a Result of minus its costs.
There is deliberately no profit per cargo type: splitting the running costs
between cargos would need an arbitrary key. The capacity column is there so
you can compare "share of income" with "share of the train" yourself.

## Installation

Subscribe on mod.io or in the in-game Mod-Hub, then enable the mod when
loading or creating a game.

Manual installation: copy the folder `kampfmoehre_running_costs_1` into the
game's local mod directory, on Linux
`~/.local/share/Steam/userdata/<steam-id>/3493540/local/mods/`.

## How it works

The cost rule above was measured in October 2026 with a single truck on a
test map: the game books `MAINTENANCE/VEHICLE` every 60 s of game time, and a
minute spent in a state costs `runningCost × 60 / 1461 × factor`.
`api.engine.util.vehicle.getRunningCost` returns the yearly value including
the condition surcharge; the sum of the consist parts' `runningCosts` is the
rate of a healthy vehicle.

- `content/running_costs/running_costs.gs.lua` + `.script.lua`: a game
  script (engine side) that classifies every vehicle every 3 s of game time
  and accumulates seconds per state into a per-vehicle ring of 7 buckets of
  ~244 s (`cost_history.lua`, the oldest bucket counts pro rata), together
  with the healthy rate and the condition surcharge. It also keeps a compact per-vehicle summary of the window
  in the game-script state, which is saved with the game.
- `content/gui/kampfmoehre_running_costs/running_costs.script.lua`: the GUI.
  It reads the summaries through the game script's `GAME_SCRIPT` component,
  renders the table (`cost_rows.lua` turns summaries into rows), adds the
  vehicle window row (`::VehicleEowExtensionPoint`) and puts the table into
  the line window's "Balance" card by wrapping `content_card.ContentCard`
  for the card with `localKey == "lineBalance"`.
- Booked income of an account: the game's own "last year" query
  (`calculateBalance(entity, t0, t1, true)`) is income minus running costs
  of the entity; subtracting the two maintenance types a vehicle or line
  account carries (`VEHICLE`, `VEHICLE_MAINTENANCE`) leaves the income. Its
  income entries answer to the type `OTHER`, so that one must not be
  subtracted. The vehicle's not-yet-booked unload income is added (the game
  books at departure, the events arrive per item while unloading). Verified
  on a single truck: 434 440 against the game's own income bar, exactly.
- `content/running_costs/income.gs.lua` + `income.script.lua`: a second,
  event-only game script with its own small state (a batch of paid items
  arrives on every unload; the cost sampler's state would be too expensive
  to read and write that often). Each batch of paid items becomes a few
  compact records in the collector's own state, a queue that only keeps the
  last 8 s (a write of such a tiny state costs about 0.3 ms);
  the cost sampler reads that queue every 3 s and moves the records it has
  not seen into the income rings of its own state. A delivery therefore
  shows in the income table a few seconds late. The handler never returns a
  value, so prices are untouched.
- `cost_classes.lua` is the single list of states, factors, texts and
  colours; the sampler and the GUI both iterate it, so later versions can add
  classes (e.g. speed buckets) without touching the table code.

Cost, measured on a save with 364 vehicles: about 7 ms of one simulation
pool thread every 3 s of game time (reading and writing the saved state is
two thirds of it), no visible frame-rate change; the income collector adds
about 0.3 ms per batch of paid items (7 batches per second of game time on
that save, so ~2 ms per game second). Open windows
read one small summary and one income ring per shown vehicle every 2 s.

## Development

```
./sync.sh                         # rsync the mod into the game's staging area
luajit test/cost_classes_test.lua # pure modules, no game needed
luajit test/cost_history_test.lua
luajit test/cost_rows_test.lua
```

Reload the savegame to pick up changed files. Log lines start with
`[kampfmoehre_running_costs]`.

## License

MIT, see `LICENSE`.
