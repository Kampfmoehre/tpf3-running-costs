# Changelog

## 0.1.1 (2026-10-21)

- "1 vehicle with less data" in the singular.
- The oldest part of the window is weighted against the data that actually exists there, so a history that
  started mid-bucket no longer under-counts for its first minutes with a full window.
- A vehicle that lags a few seconds behind the others between two reads no longer flickers into "less data".
- Less work per refresh in the windows; a state that keeps failing is rebuilt after ten attempts.

## 0.1.0 (2026-10-21)

- First release: live "Now €X/min" line in the vehicle window with the current rate, state and condition
  surcharge; expandable table of the last default game year (24 min of game time) by state: driving,
  waiting en route, at terminal (40 %), in depot (5 %), condition surcharge, sum.
- The same table for all vehicles of a line under the income graph of the line window's "Balance" card,
  with the amount booked by the game for comparison.
- The history is sampled every 3 s of game time and saved with the game.
