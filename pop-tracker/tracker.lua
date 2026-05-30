--[[
    tracker.lua  --  pure, framework-free state/timer logic for pop-tracker.

    No Ashita / game dependencies live here so it can be unit-tested offline
    with `lua test/run.lua`.  The main addon (pop-tracker.lua) feeds this module
    facts it has read from the game (a mob died, current status, the clock) and
    asks it back for display rows.

    Concepts
    --------
    * watch    : the persistent "watch list".  A mob stays here until /untrack,
                 regardless of how many times it dies and repops.
                 watch[serverId] = { name=, mobName=, respawn=, index=, armed= }
    * timers   : the *transient* per-death countdowns.  Created when a watched
                 mob dies, removed ~popDuration seconds after it pops.  Only mobs
                 with an active timer are drawn in the window -- which is why a
                 line "disappears" after pop even though the mob is still tracked.
]]

local Tracker = {}
Tracker.__index = Tracker

-- How long the "pop" label lingers before the line is removed (seconds).
local DEFAULT_POP_DURATION = 5

------------------------------------------------------------------------------
-- helpers (also exported as Tracker.xxx so tests/main can reuse them)
------------------------------------------------------------------------------

-- Parse a respawn time.  Accepts a number, "mm:ss" ("5:50" -> 350) or a bare
-- seconds string ("350" -> 350).  Returns nil on anything unparseable.
function Tracker.parseTime(v)
    if type(v) == 'number' then
        return v >= 0 and v or nil
    end
    if type(v) ~= 'string' then return nil end
    local s = v:match('^%s*(.-)%s*$')
    if s == '' then return nil end
    local m, sec = s:match('^(%d+):(%d+)$')
    if m then
        return tonumber(m) * 60 + tonumber(sec)
    end
    if s:match('^%d+$') then
        return tonumber(s)
    end
    return nil
end

-- Format a number of seconds as m:ss for the countdown.
function Tracker.formatClock(seconds)
    local s = math.floor(math.max(0, seconds))
    return string.format('%d:%02d', math.floor(s / 60), s % 60)
end

------------------------------------------------------------------------------
-- construction
------------------------------------------------------------------------------

function Tracker.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Tracker)
    self.watch = {}          -- [serverId] = entry
    self.timers = {}         -- [serverId] = { diedAt=, popAt=, popped=, expireAt= }
    self.order = {}          -- array of serverIds, preserves track order for slots
    self.popDuration = opts.popDuration or DEFAULT_POP_DURATION
    -- nil / 0 means "no default" -> a mob with no respawn set counts as unknown.
    self.defaultRespawn = (opts.defaultRespawn and opts.defaultRespawn > 0)
        and opts.defaultRespawn or nil
    return self
end

------------------------------------------------------------------------------
-- watch-list management
------------------------------------------------------------------------------

-- Add (or update fields of) a watched mob.  `info` keys are all optional:
--   mobName, index, respawn, name, armed
-- armed controls whether a death can fire immediately.  /track defaults it true
-- (you can only target a living mob, so the next dead reading is a real kill);
-- restored/imported mobs pass armed=false so they must be seen alive first and
-- a corpse already lying in the area on load is NOT mistaken for a fresh kill.
function Tracker:track(serverId, info)
    assert(serverId ~= nil, 'serverId required')
    info = info or {}
    local w = self.watch[serverId]
    local isNew = not w
    if isNew then
        local armed = true
        if info.armed ~= nil then armed = info.armed end
        w = { armed = armed }
        self.watch[serverId] = w
        self.order[#self.order + 1] = serverId
    end
    if info.mobName ~= nil then w.mobName = info.mobName end
    if info.index ~= nil then w.index = info.index end
    if info.respawn ~= nil then w.respawn = info.respawn end
    if info.name ~= nil then w.name = info.name end
    return isNew
end

function Tracker:untrack(serverId)
    if not self.watch[serverId] then return false end
    self.watch[serverId] = nil
    self.timers[serverId] = nil
    for i, id in ipairs(self.order) do
        if id == serverId then table.remove(self.order, i) break end
    end
    return true
end

function Tracker:untrackAll()
    self.watch, self.timers, self.order = {}, {}, {}
end

function Tracker:isTracked(serverId)
    return self.watch[serverId] ~= nil
end

function Tracker:count()
    return #self.order
end

-- Update the live entity index for a watched mob (the index can change when a
-- mob repops into a different slot).  No-op if not tracked.
function Tracker:setIndex(serverId, index)
    local w = self.watch[serverId]
    if w then w.index = index end
end

function Tracker:rename(serverId, name)
    local w = self.watch[serverId]
    if not w then return false end
    w.name = (name and name ~= '') and name or nil
    return true
end

function Tracker:setRespawn(serverId, seconds)
    local w = self.watch[serverId]
    if not w then return false end
    w.respawn = seconds
    -- If a countdown is already running with an unknown/old time, recompute it.
    local t = self.timers[serverId]
    if t and not t.popped then
        t.popAt = seconds and (t.diedAt + seconds) or nil
    end
    return true
end

------------------------------------------------------------------------------
-- death / status observation
------------------------------------------------------------------------------

-- Start a respawn countdown for a watched mob.  Returns false if not tracked.
function Tracker:onDeath(serverId, now)
    local w = self.watch[serverId]
    if not w then return false end
    local respawn = w.respawn or self.defaultRespawn
    self.timers[serverId] = {
        diedAt  = now,
        popAt   = respawn and (now + respawn) or nil,  -- nil -> unknown countdown
        popped  = false,
        expireAt = nil,
    }
    return true
end

-- Feed the current liveness of a watched mob (isDead = caller decided the
-- entity's status is a death status).  Encapsulates edge-triggering + re-arming
-- so a lingering corpse, or the same mob dying again after a repop, is handled
-- correctly.  Returns 'died' on the frame a fresh death is registered.
function Tracker:observe(serverId, isDead, now)
    local w = self.watch[serverId]
    if not w then return nil end
    if w.armed == nil then w.armed = true end
    if isDead then
        if w.armed then
            w.armed = false
            self:onDeath(serverId, now)
            return 'died'
        end
    else
        w.armed = true   -- mob is alive -> ready to catch the next death
    end
    return nil
end

-- Advance timers.  Transitions dead->pop when the countdown hits 0, and removes
-- the timer (line disappears) popDuration seconds after pop.  Returns the list
-- of serverIds whose lines were removed this tick.
function Tracker:update(now)
    local removed
    for id, t in pairs(self.timers) do
        if not t.popped and t.popAt and now >= t.popAt then
            t.popped = true
            -- Anchor to the actual pop moment (popAt), not the frame we noticed
            -- it, so "pop" shows for popDuration regardless of frame timing.
            t.expireAt = t.popAt + self.popDuration
        end
        if t.popped and t.expireAt and now >= t.expireAt then
            removed = removed or {}
            removed[#removed + 1] = id
        end
    end
    if removed then
        for _, id in ipairs(removed) do self.timers[id] = nil end
    end
    return removed or {}
end

------------------------------------------------------------------------------
-- display
------------------------------------------------------------------------------

-- Best display label: custom name > game mob name > serverId.
function Tracker:label(serverId)
    local w = self.watch[serverId]
    if not w then return tostring(serverId) end
    return w.name or w.mobName or tostring(serverId)
end

-- Rows to draw in the window.  Only mobs with an active timer appear, in track
-- order, each assigned a stable 1-based slot for use by slot-targeted commands.
function Tracker:rows(now)
    local rows = {}
    for _, id in ipairs(self.order) do
        local t = self.timers[id]
        if t then
            local row = {
                slot = #rows + 1,
                serverId = id,
                label = self:label(id),
            }
            if t.popped then
                row.state, row.text = 'pop', 'pop'
            elseif t.popAt then
                local rem = math.max(0, t.popAt - now)
                row.state, row.remaining = 'dead', rem
                row.text = Tracker.formatClock(rem)
            else
                row.state, row.text = 'unknown', '--:--'  -- died with no time set
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

-- Resolve a 1-based display slot to a serverId (nil if out of range).
function Tracker:serverIdBySlot(slot, now)
    for _, r in ipairs(self:rows(now)) do
        if r.slot == slot then return r.serverId end
    end
    return nil
end

------------------------------------------------------------------------------
-- persistence helpers (plain tables, so main can hand them to settings.lua)
------------------------------------------------------------------------------

-- Export only the durable watch fields (not transient timers/index/armed).
function Tracker:exportWatch()
    local out = {}
    for _, id in ipairs(self.order) do
        local w = self.watch[id]
        out[tostring(id)] = {
            name    = w.name,
            mobName = w.mobName,
            respawn = w.respawn,
        }
    end
    return out
end

-- Rebuild the watch list from a previously exported table.
function Tracker:importWatch(t)
    if not t then return end
    for key, w in pairs(t) do
        local id = tonumber(key) or key
        -- armed=false: a restored mob must be observed alive before any death
        -- counts, so corpses already in the zone on load don't start timers.
        self:track(id, { name = w.name, mobName = w.mobName, respawn = w.respawn, armed = false })
    end
end

return Tracker
