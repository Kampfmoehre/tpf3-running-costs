-- Per-vehicle cost history of Running Cost Breakdown: a ring of time buckets
-- holding, per cost class, the game seconds spent, plus the vehicle's static
-- (healthy) rate per year as seen in that bucket and the maintenance-state
-- surcharge charged in it. The cost per class is derived in window() as
-- seconds × factor × rate / year, so a bucket is small (the state is copied
-- on every get/set of the game script, ~400 vehicles × 13 buckets).
--
-- 7 buckets of 243 500 ms: 6 cover one default game year (1 461 000 ms of
-- game time, api.util.getDefaultYearDuration()), the 7th makes sure a full
-- window is always inside the ring. window() counts every bucket that
-- overlaps the window, the oldest one pro rata by its overlap (assuming the
-- time inside a bucket is spread evenly); coverage is the time span the
-- counted buckets stand for, capped at the window. Few, large buckets keep
-- the game-script state small: it is copied on every get/set of the
-- sampler (~400 vehicles).
--
-- The tables live in the game-script state (saved with the game), so every
-- function tolerates buckets without t/c/s and class keys it has never seen.
-- No game API, unit-tested with plain luajit (test/cost_history_test.lua).
local M = {}

M.BUCKET_MS = 243500
M.BUCKETS = 7

local function bucketStart(ms)
	return math.floor(ms / M.BUCKET_MS) * M.BUCKET_MS
end

-- Ring = { start = ms of the first bucket, head = slot of the newest bucket
-- (0 = none), b = { [slot] = Bucket } }; a Bucket always has t0, the users
-- add their fields: costs t = {key = s}, r = rate/year, s = surcharge;
-- income inc = { [key] = { n, base, ok, q } }.
function M.newRing(nowMs)
	return { start = bucketStart(nowMs or 0), head = 0, b = {} }
end

-- History = Ring + first = ms of the first sample (coverage counts from
-- here, not from the bucket start)
function M.new(nowMs)
	local h = M.newRing(nowMs)
	h.first = nowMs or 0
	return h
end

-- the bucket for nowMs, opening it (reusing the oldest slot) when needed;
-- a step back in time starts the ring over
function M.bucketFor(h, nowMs)
	local t0 = bucketStart(nowMs)
	local cur = h.head > 0 and h.b[h.head] or nil
	if cur and cur.t0 == t0 then return cur end
	if nowMs < h.start or (cur and t0 < cur.t0) then
		h.start, h.head, h.b = t0, 0, {}
		if h.first ~= nil then h.first = nowMs end
	end
	h.head = h.head % M.BUCKETS + 1
	local nb = { t0 = t0 }
	h.b[h.head] = nb
	return nb
end
local bucketFor = M.bucketFor

-- share of a bucket's data that lies inside the window [nowMs - windowMs, nowMs]:
-- 0 outside, 1 for a bucket fully inside, pro rata for the oldest one (its
-- data starts at `first` when the history began inside it)
function M.bucketWeight(t0, nowMs, windowMs, first)
	local from = nowMs - windowMs
	if t0 + M.BUCKET_MS <= from or t0 > nowMs then return 0 end
	-- nothing before the history began counts (an income ring may be older
	-- than the cost history whose `first` it is read with)
	if first and t0 + M.BUCKET_MS <= first then return 0 end
	local dataStart = t0
	if first and first > dataStart then dataStart = first end
	if from <= dataStart then return 1 end
	local span = t0 + M.BUCKET_MS - dataStart
	if span <= 0 then return 0 end
	return math.max(0, (t0 + M.BUCKET_MS - from) / span)
end

-- dtMs of game time spent in class `key` at costPerYearStatic (the healthy
-- rate; a consist change inside one bucket is attributed to the new rate)
-- with surchargePerYear on top, charged at `factor`
function M.add(h, nowMs, dtMs, key, costPerYearStatic, surchargePerYear, factor, yearMs)
	local b = bucketFor(h, nowMs)
	b.t = b.t or {}
	b.r = b.r or 0
	b.s = b.s or 0
	local before = 0
	for __, v in pairs(b.t) do before = before + v end
	local dt = dtMs / 1000
	b.t[key] = (b.t[key] or 0) + dt
	-- the bucket's rate is the seconds-weighted mean, so a consist change
	-- inside a bucket keeps the old rate for the seconds before it
	if before + dt > 0 then
		b.r = ((b.r or 0) * before + (costPerYearStatic or 0) * dt) / (before + dt)
	end
	b.s = (b.s or 0) + (surchargePerYear or 0) * dtMs / yearMs * factor
end

-- factorOf(key) -> the class factor, yearMs -> the default year ->
-- Summary = { cov = covered ms (<= windowMs), t = {key = s}, c = {key = cost},
--   s = surcharge, total = sum of c + s }
function M.window(h, nowMs, windowMs, factorOf, yearMs)
	local out = { cov = 0, t = {}, c = {}, s = 0, total = 0 }
	if not h or type(h.b) ~= "table" then return out end
	local from = nowMs - windowMs
	local oldest = nil
	for __, b in pairs(h.b) do
		local weight = (type(b) == "table" and b.t0) and M.bucketWeight(b.t0, nowMs, windowMs, h.first) or 0
		if weight > 0 then
			if oldest == nil or b.t0 < oldest then oldest = b.t0 end
			local perSecond = (b.r or 0) / yearMs * 1000
			for k, v in pairs(b.t or {}) do
				local sec = v * weight
				out.t[k] = (out.t[k] or 0) + sec
				local cost = sec * factorOf(k) * perSecond
				out.c[k] = (out.c[k] or 0) + cost
				out.total = out.total + cost
			end
			out.s = out.s + (b.s or 0) * weight
		end
	end
	out.total = out.total + out.s
	if oldest ~= nil then
		local begin = math.max(oldest, from)
		if h.first and h.first > begin then begin = h.first end
		out.cov = math.min(windowMs, nowMs - begin)
	end
	return out
end

-- one paid item: base = basePrice × distance, ok = true/false (delivery
-- quality) or nil (no quality, e.g. passengers)
function M.addIncome(ring, nowMs, key, base, ok)
	local b = bucketFor(ring, nowMs)
	b.inc = b.inc or {}
	local e = b.inc[key]
	if e == nil then
		e = { n = 0, base = 0, ok = 0, q = 0 }
		b.inc[key] = e
	end
	e.n = e.n + 1
	e.base = e.base + (base or 0)
	if ok ~= nil then
		e.q = e.q + 1
		if ok == true then e.ok = e.ok + 1 end
	end
end

-- the bucket for an event time that may lie behind the newest bucket (the
-- income collector flushes per-thread buffers up to a flush interval late):
-- the bucket holding tMs if it still exists, a new bucket when tMs is newer
-- than the head, else the head bucket (a few seconds misattributed instead
-- of resetting the ring)
local function bucketAt(ring, tMs)
	local t0 = bucketStart(tMs)
	local cur = ring.head > 0 and ring.b[ring.head] or nil
	if cur == nil or t0 > cur.t0 then return bucketFor(ring, tMs) end
	if cur.t0 == t0 then return cur end
	for __, b in pairs(ring.b) do
		if type(b) == "table" and b.t0 == t0 then return b end
	end
	return cur
end

-- n items of cargo `key` paid at tMs with Σ base, ok of them on time, q of
-- them with a known quality (buffered counts; see addIncome for single items)
function M.addIncomeCounts(ring, tMs, key, n, base, ok, q)
	local b = bucketAt(ring, tMs)
	b.inc = b.inc or {}
	local e = b.inc[key]
	if e == nil then
		e = { n = 0, base = 0, ok = 0, q = 0 }
		b.inc[key] = e
	end
	e.n = e.n + (n or 0)
	e.base = e.base + (base or 0)
	e.ok = e.ok + (ok or 0)
	e.q = e.q + (q or 0)
end

-- income inside the window, weighted like the costs; `first` is the cost
-- history's first sample of the same vehicle -> { [key] = { n, base, ok, q } }
function M.windowIncome(ring, nowMs, windowMs, first)
	local out = {}
	if not ring or type(ring.b) ~= "table" then return out end
	for __, b in pairs(ring.b) do
		local weight = (type(b) == "table" and b.t0) and M.bucketWeight(b.t0, nowMs, windowMs, first) or 0
		if weight > 0 and type(b.inc) == "table" then
			for k, e in pairs(b.inc) do
				local o = out[k]
				if o == nil then
					o = { n = 0, base = 0, ok = 0, q = 0 }
					out[k] = o
				end
				o.n = o.n + (e.n or 0) * weight
				o.base = o.base + (e.base or 0) * weight
				o.ok = o.ok + (e.ok or 0) * weight
				o.q = o.q + (e.q or 0) * weight
			end
		end
	end
	return out
end

-- Income queue -------------------------------------------------------------
-- The income collector (income.script.lua) aggregates one batch of paid items
-- into a Buffer, appends it as compact records to the tiny queue in its own
-- state and trims records older than a few seconds; the cost sampler reads
-- that state every sample and consumes the records it has not seen (by id)
-- into the rings of its own state. A per-batch write of a tiny state is
-- cheap; a per-batch write of the rings was not.
-- Buffer = { items, since = ms of the oldest item, batches,
--   byRing = { [ringKey] = { [bucketT0] = { [cargo] = { n, base, ok, q, t } } } } }
function M.newBuffer()
	return { items = 0, since = nil, batches = 0, byRing = {} }
end

function M.bufferAdd(buf, ringKey, key, tMs, base, ok)
	local perRing = buf.byRing[ringKey]
	if perRing == nil then
		perRing = {}
		buf.byRing[ringKey] = perRing
	end
	local t0 = bucketStart(tMs)
	local perBucket = perRing[t0]
	if perBucket == nil then
		perBucket = {}
		perRing[t0] = perBucket
	end
	local e = perBucket[key]
	if e == nil then
		e = { n = 0, base = 0, ok = 0, q = 0, t = tMs }
		perBucket[key] = e
	end
	e.n = e.n + 1
	e.base = e.base + (base or 0)
	if ok ~= nil then
		e.q = e.q + 1
		if ok == true then e.ok = e.ok + 1 end
	end
	buf.items = buf.items + 1
	if buf.since == nil or tMs < buf.since then buf.since = tMs end
end

-- appends the buffer's entries to the queue as records { rk, key, t, n, base,
-- ok, q } under ids "<tag>-<n>" (tag unique per Lua state), empties the
-- buffer; returns the number of records added
function M.queueAppend(queue, buf, tag, nowMs)
	if buf == nil or buf.items == 0 then return 0 end
	buf.seq = buf.seq or 0
	local added = 0
	for rk, perRing in pairs(buf.byRing) do
		for __, perBucket in pairs(perRing) do
			for key, e in pairs(perBucket) do
				buf.seq = buf.seq + 1
				queue[tag .. "-" .. buf.seq] = { rk = rk, key = key, t = e.t, n = e.n, base = e.base, ok = e.ok, q = e.q, at = nowMs }
				added = added + 1
			end
		end
	end
	buf.items, buf.since, buf.batches, buf.byRing = 0, nil, 0, {}
	return added
end

-- drops records appended more than maxAgeMs before nowMs
function M.queueTrim(queue, nowMs, maxAgeMs)
	for id, rec in pairs(queue) do
		if type(rec) ~= "table" or (rec.at or rec.t or 0) < nowMs - maxAgeMs then queue[id] = nil end
	end
end

M.SEEN_MS = 60000   -- how long consumed ids are remembered (> the collector's trim age)

-- moves every record not yet in `seen` into rings[rec.rk] (created when
-- missing); remembers the ids with their time and forgets ids older than
-- SEEN_MS; returns the number of records consumed
function M.queueConsume(queue, rings, seen, nowMs)
	local n = 0
	for id, rec in pairs(queue or {}) do
		if type(rec) == "table" and seen[id] == nil then
			local ring = rings[rec.rk]
			if ring == nil then
				ring = M.newRing(nowMs)
				rings[rec.rk] = ring
			end
			M.addIncomeCounts(ring, rec.t or nowMs, rec.key, rec.n, rec.base, rec.ok, rec.q)
			seen[id] = nowMs
			n = n + 1
		end
	end
	for id, t in pairs(seen) do
		if t < nowMs - M.SEEN_MS then seen[id] = nil end
	end
	return n
end

return M
