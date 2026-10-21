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

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
