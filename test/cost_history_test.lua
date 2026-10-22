-- run: luajit test/cost_history_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "cost_history"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end
local function near(name, got, want, tol)
	check(name, type(got) == "number" and math.abs(got - want) <= tol, string.format("got %s, want %s", tostring(got), tostring(want)))
end

local Y = 1461000
check("constants: 6 buckets cover a default year, one spare", M.BUCKET_MS == 243500 and M.BUCKETS == 7 and 6 * M.BUCKET_MS == Y)
-- window() derives the cost per class from seconds × factor × the bucket's rate
local F = function(key) return key == "terminal" and 0.4 or (key == "depot" and 0.05 or 1.0) end
local function W(h, now, win) return M.window(h, now, win, F, Y) end

local h = M.new(0)
M.add(h, 2000, 2000, "driving", 1461000, 0, 1.0, Y)    -- 2 s at 1 461 000/yr = 2000 cost
local w = W(h, 2000, Y)
near("cost of 2 s driving", w.c.driving, 2000, 1e-6)
near("seconds", w.t.driving, 2, 1e-9)
near("coverage of a young history", w.cov, 2000, 1e-9)
M.add(h, 4000, 2000, "terminal", 1461000, 292200, 0.4, Y) -- 20 % surcharge at factor 0.4
near("terminal cost", W(h, 4000, Y).c.terminal, 800, 1e-6)
near("surcharge", W(h, 4000, Y).s, 160, 1e-6)
near("total", W(h, 4000, Y).total, 2960, 1e-6)
near("coverage grows", W(h, 4000, Y).cov, 4000, 1e-9)

-- static changes between buckets: the new bucket uses the new rate
local h2 = M.new(0)
M.add(h2, 1000, 1000, "driving", 1000 * Y / 1000, 0, 1.0, Y)              -- 1 s at 1000/s -> 1000
M.add(h2, M.BUCKET_MS + 1000, 1000, "driving", 2000 * Y / 1000, 0, 1.0, Y) -- 1 s at 2000/s -> 2000
near("static change", W(h2, M.BUCKET_MS + 1000, Y).c.driving, 3000, 1e-6)
check("two buckets open, each with its rate", h2.b[1] ~= nil and h2.b[2] ~= nil and h2.b[2].t0 == M.BUCKET_MS and h2.b[1].r == Y and h2.b[2].r == 2 * Y)
check("bucket holds no per-class cost table", h2.b[1].c == nil)

-- static changes inside one bucket: the bucket's rate is the seconds-weighted
-- mean, so the pre-change seconds keep their old rate in the total
local h2b = M.new(0)
M.add(h2b, 1000, 1000, "driving", 1000 * Y / 1000, 0, 1.0, Y)   -- 1 s at 1000/s
M.add(h2b, 2000, 1000, "driving", 2000 * Y / 1000, 0, 1.0, Y)   -- 1 s at 2000/s, same bucket
near("rate change inside a bucket", W(h2b, 2000, Y).c.driving, 3000, 1e-6)
M.add(h2b, 3000, 1000, "terminal", 4000 * Y / 1000, 0, 0.4, Y)  -- 1 s at 4000/s, factor 0.4
near("mean rate spans all classes of the bucket", W(h2b, 3000, Y).total, 2 * (7000 / 3) + 0.4 * (7000 / 3), 1e-6)

-- rollover: 8 buckets written, the ring keeps 7; the window = 6 full buckets
-- plus the oldest one pro rata (here 10 ms short of full), bucket 0 is gone
local h3 = M.new(0)
for i = 0, 7 do M.add(h3, i * M.BUCKET_MS + 10, 1000, "driving", Y, 0, 1.0, Y) end
local w3 = W(h3, 7 * M.BUCKET_MS + 10, Y)
near("window keeps 7 buckets, oldest pro rata", w3.c.driving, 7 * 1000 - 1000 * 10 / M.BUCKET_MS, 1e-3)
near("coverage capped at the window", w3.cov, Y, 1e-9)
-- pro rata: a window ending mid-bucket counts the oldest bucket by its overlap
local h7 = M.new(0)
M.add(h7, 10, 1000, "driving", Y, 0, 1.0, Y)                       -- bucket 0: 1000
M.add(h7, M.BUCKET_MS + 10, 1000, "driving", Y, 0, 1.0, Y)         -- bucket 1: 1000
local w7 = W(h7, M.BUCKET_MS + 10, M.BUCKET_MS / 2 + 10)           -- window starts at half of bucket 0
near("oldest bucket weighted by overlap", w7.c.driving, 1500, 1e-6)
near("pro rata seconds too", w7.t.driving, 1.5, 1e-9)
near("coverage of a pro rata window", w7.cov, M.BUCKET_MS / 2 + 10, 1e-9)
local n = 0
for __ in pairs(h3.b) do n = n + 1 end
check("ring never exceeds BUCKETS", n == M.BUCKETS, tostring(n))

-- a shorter window only sums recent buckets: 2 full ones + the oldest pro rata
local w3s = W(h3, 7 * M.BUCKET_MS + 10, 2 * M.BUCKET_MS)
near("short window", w3s.c.driving, 3 * 1000 - 1000 * 10 / M.BUCKET_MS, 1e-3)

-- unknown keys and sparse buckets tolerated
local h4 = M.new(0); M.add(h4, 500, 500, "speed_bucket_90", Y, 0, 1.0, Y)
h4.b[h4.head].r = nil
check("unknown key, missing rate", W(h4, 500, Y).t.speed_bucket_90 == 0.5 and W(h4, 500, Y).total == 0)
h4.b[h4.head].t = nil; h4.b[h4.head].s = nil
check("missing t and s", W(h4, 500, Y).total == 0 and next(W(h4, 500, Y).t) == nil)

-- time jump backwards (before the history's first bucket) resets
local h5 = M.new(500000); M.add(h5, 500500, 500, "terminal", Y, 0, 0.4, Y)
M.add(h5, 100, 100, "driving", Y, 0, 1.0, Y)
check("reset on backwards time", W(h5, 100, Y).t.terminal == nil and W(h5, 100, Y).t.driving == 0.1)

-- pro rata with a history that starts mid-bucket: the oldest bucket's data
-- spans [first, bucket end], and the window cut is measured against that span
local h9 = M.new(M.BUCKET_MS / 2)                               -- first sample at half of bucket 0
M.add(h9, M.BUCKET_MS / 2 + 1000, 1000, "driving", Y, 0, 1.0, Y) -- 1 s -> 1000
M.add(h9, M.BUCKET_MS + 10, 10, "driving", 0, 0, 1.0, Y)       -- bucket 1 exists, no cost
local w9 = W(h9, M.BUCKET_MS + 10, M.BUCKET_MS / 4 + 10)        -- window starts at 3/4 of bucket 0
near("first mid-bucket: half of the data span is inside the window", w9.c.driving, 500, 1e-6)
near("first mid-bucket: coverage from the window start", w9.cov, M.BUCKET_MS / 4 + 10, 1e-9)
local w9b = W(h9, M.BUCKET_MS + 10, M.BUCKET_MS + 10)           -- window starts at 0, before first
near("window before first: full weight", w9b.c.driving, 1000, 1e-6)

-- coverage starts at the first sample, not at the start of its bucket
local h8 = M.new(100000)                                   -- bucket 0 starts at 0
M.add(h8, 100000, 1000, "driving", Y, 0, 1.0, Y)
near("coverage from the first sample", W(h8, 160000, Y).cov, 60000, 1e-9)
h8.first = nil                                             -- state written by an older version
near("without first: falls back to the bucket start", W(h8, 160000, Y).cov, 160000, 1e-9)

-- empty history
local e = W(M.new(0), 0, Y)
check("empty history", e.cov == 0 and e.total == 0 and next(e.t) == nil)

-- a long gap (paused game, big dt) lands in the current bucket only
local h6 = M.new(0)
M.add(h6, 10, 10, "driving", Y, 0, 1.0, Y)
M.add(h6, 5 * M.BUCKET_MS, 3 * M.BUCKET_MS, "driving", Y, 0, 1.0, Y)
local n6 = 0
for __ in pairs(h6.b) do n6 = n6 + 1 end
check("gap: buckets in between are not created", n6 == 2 and h6.b[2].t0 == 5 * M.BUCKET_MS, tostring(n6))

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

-- buffered income: counts arrive late (up to a flush interval after the
-- events) and must land in the bucket of their event time, never reset the ring
local r4 = M.newRing(0)
M.addIncomeCounts(r4, 1000, 7, 3, 300, 2, 3)                 -- 3 items at t=1 s
local I4 = M.windowIncome(r4, 2000, Y, nil)
check("counts added", I4[7].n == 3 and I4[7].base == 300 and I4[7].ok == 2 and I4[7].q == 3)
M.addIncomeCounts(r4, M.BUCKET_MS + 500, 7, 1, 100, 1, 1)    -- bucket 1 opens
M.addIncomeCounts(r4, M.BUCKET_MS - 500, 7, 1, 50, 0, 1)     -- late item of bucket 0
check("late item lands in its own bucket", r4.b[1].inc[7].n == 4 and r4.b[2].inc[7].n == 1 and r4.head == 2)
M.addIncomeCounts(r4, -5000, 7, 1, 10, 0, 0)                 -- older than the ring start: head bucket, no reset
check("too-old item goes to the newest bucket, ring kept", r4.head == 2 and r4.b[2].inc[7].n == 2 and r4.b[1].inc[7].n == 4)

-- income before the cost history's first sample must not count (review 0.2.0 #1)
near("weight: bucket entirely before first is 0", M.bucketWeight(0, 3 * M.BUCKET_MS, 6 * M.BUCKET_MS, 2 * M.BUCKET_MS), 0, 1e-9)
local r5 = M.newRing(0)
M.addIncomeCounts(r5, 100, 7, 1, 10, 0, 0)
M.addIncomeCounts(r5, 2 * M.BUCKET_MS + 100, 7, 1, 10, 0, 0)
near("items before first are dropped", M.windowIncome(r5, 2 * M.BUCKET_MS + 200, Y, 2 * M.BUCKET_MS)[7].n, 1, 1e-9)

-- income queue: the collector appends compact records per batch to a tiny
-- state, the sampler consumes new ones (by id) into the rings
local buf = M.newBuffer()
check("empty buffer", buf.items == 0 and buf.since == nil)
M.bufferAdd(buf, 25245, 7, 6 * M.BUCKET_MS + 10, 100, true)
M.bufferAdd(buf, 25245, 7, 6 * M.BUCKET_MS + 20, 50, nil)
M.bufferAdd(buf, "L9", 3, 6 * M.BUCKET_MS + 20, 7, false)
check("buffer counts, since = oldest item", buf.items == 3 and buf.since == 6 * M.BUCKET_MS + 10)
local q = {}
local added = M.queueAppend(q, buf, "t1", 6 * M.BUCKET_MS + 30)
check("one record per ring and cargo, ids from the tag", added == 2 and q["t1-1"] ~= nil and q["t1-2"] ~= nil)
local recs = { q["t1-1"], q["t1-2"] }
table.sort(recs, function(a, b) return tostring(a.rk) < tostring(b.rk) end)
check("record fields", recs[1].rk == 25245 and recs[1].key == 7 and recs[1].n == 2 and recs[1].base == 150 and recs[1].ok == 1 and recs[1].q == 1 and recs[1].t == 6 * M.BUCKET_MS + 10)
check("line-level record", recs[2].rk == "L9" and recs[2].n == 1 and recs[2].q == 1 and recs[2].ok == 0)
M.queueTrim(q, 6 * M.BUCKET_MS + 30 + 10000, 10000)
check("trim keeps records younger than the age", q["t1-1"] ~= nil)
M.queueTrim(q, 6 * M.BUCKET_MS + 30 + 10001, 10000)
check("trim drops old records", next(q) == nil)
-- consuming: every record once, even when read twice
local q2 = {}
M.queueAppend(q2, buf, "t2", 0)             -- buf was emptied by the first append
check("append of an empty buffer adds nothing", next(q2) == nil)
M.bufferAdd(buf, 25245, 7, 6 * M.BUCKET_MS + 40, 10, true)
M.queueAppend(q2, buf, "t2", 6 * M.BUCKET_MS + 40)
local rings, seen = {}, {}
check("consume adds once", M.queueConsume(q2, rings, seen, 6 * M.BUCKET_MS + 40) == 1 and M.queueConsume(q2, rings, seen, 6 * M.BUCKET_MS + 40) == 0)
check("consumed into the ring", M.windowIncome(rings[25245], 6 * M.BUCKET_MS + 50, Y, nil)[7].n == 1)
M.queueConsume(q2, rings, seen, 6 * M.BUCKET_MS + 40 + 120000)
check("seen set pruned after a while", next(seen) == nil)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
