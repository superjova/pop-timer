--[[
    Offline unit tests for the pure logic in tracker.lua.
    Run from the addon root:  lua test/run.lua   (or luajit / lua5.1)
    No game client required.
]]

-- Make the sibling addon files require-able by bare name, mirroring how Ashita
-- puts the addon folder on package.path.
package.path = package.path .. ';./?.lua;./../?.lua'

local Tracker = require('tracker')

local tests, failures = 0, 0
local function check(cond, msg)
    tests = tests + 1
    if not cond then
        failures = failures + 1
        print(('  FAIL: %s'):format(msg or '(no message)'))
    end
end
local function eq(a, b, msg)
    check(a == b, ('%s  (got %s, want %s)'):format(msg or 'eq', tostring(a), tostring(b)))
end

------------------------------------------------------------------------------
print('parseTime')
eq(Tracker.parseTime('350'), 350, 'bare seconds')
eq(Tracker.parseTime('5:50'), 350, 'mm:ss')
eq(Tracker.parseTime('0:05'), 5, 'mm:ss small')
eq(Tracker.parseTime('10:00'), 600, 'mm:ss minutes only')
eq(Tracker.parseTime(120), 120, 'number passthrough')
eq(Tracker.parseTime('  90  '), 90, 'trims whitespace')
eq(Tracker.parseTime('abc'), nil, 'garbage -> nil')
eq(Tracker.parseTime(''), nil, 'empty -> nil')
eq(Tracker.parseTime('5:'), nil, 'partial -> nil')
eq(Tracker.parseTime(nil), nil, 'nil -> nil')

print('formatClock')
eq(Tracker.formatClock(350), '5:50', 'format 350')
eq(Tracker.formatClock(5), '0:05', 'format 5')
eq(Tracker.formatClock(0), '0:00', 'format 0')
eq(Tracker.formatClock(-3), '0:00', 'negative clamps')
eq(Tracker.formatClock(59.9), '0:59', 'floors fractional')

------------------------------------------------------------------------------
print('track / untrack / isTracked')
do
    local t = Tracker.new()
    check(t:track(100, { mobName = 'Sheep', respawn = 300 }) == true, 'first track returns isNew=true')
    check(t:track(100, { index = 5 }) == false, 'second track returns isNew=false')
    check(t:isTracked(100), 'is tracked')
    eq(t:count(), 1, 'count after dup track is 1')
    eq(t.watch[100].respawn, 300, 'respawn preserved across updates')
    eq(t.watch[100].index, 5, 'index updated on second track')
    check(t:untrack(100), 'untrack returns true')
    check(not t:isTracked(100), 'no longer tracked')
    check(not t:untrack(100), 'untrack missing returns false')
end

print('rename / label precedence')
do
    local t = Tracker.new()
    t:track(7, { mobName = 'Sheep' })
    eq(t:label(7), 'Sheep', 'falls back to mob name')
    t:track(8, {})
    eq(t:label(8), '8', 'falls back to serverId string')
    check(t:rename(7, 'North Sheep'), 'rename ok')
    eq(t:label(7), 'North Sheep', 'custom name wins')
    check(t:rename(7, ''), 'rename to empty clears')
    eq(t:label(7), 'Sheep', 'cleared name falls back to mob name')
    check(not t:rename(999, 'x'), 'rename untracked returns false')
end

------------------------------------------------------------------------------
print('death -> countdown -> pop -> disappear lifecycle')
do
    local t = Tracker.new({ popDuration = 5 })
    t:track(1, { mobName = 'NM', respawn = 10 })

    -- alive, nothing shown
    eq(#t:rows(0), 0, 'no rows while alive')

    -- dies at t=0
    eq(t:observe(1, true, 0), 'died', 'death registered')
    local rows = t:rows(0)
    eq(#rows, 1, 'one row after death')
    eq(rows[1].state, 'dead', 'state dead')
    eq(rows[1].text, '0:10', 'countdown shows full respawn')

    -- partway through
    t:update(4)
    eq(t:rows(4)[1].text, '0:06', 'countdown ticks down')

    -- corpse still reads dead -> must NOT re-register (not re-armed yet)
    eq(t:observe(1, true, 4), nil, 'lingering corpse does not re-trigger')

    -- reaches 0 -> pop
    t:update(10)
    eq(t:rows(10)[1].state, 'pop', 'becomes pop at expiry')
    eq(t:rows(10)[1].text, 'pop', 'pop label')

    -- still pop within popDuration
    t:update(13)
    eq(#t:rows(13), 1, 'pop line lingers within popDuration')

    -- after popDuration -> line removed, but still tracked
    local removed = t:update(16)
    eq(#removed, 1, 'one line removed after popDuration')
    eq(#t:rows(16), 0, 'line gone')
    check(t:isTracked(1), 'mob remains on watch list after pop')
end

print('re-arming: repop then second death starts a new timer')
do
    local t = Tracker.new({ popDuration = 5 })
    t:track(1, { respawn = 10 })
    t:observe(1, true, 0)            -- first death
    t:update(15); t:update(16)       -- pop + remove
    eq(#t:rows(16), 0, 'cleared after first cycle')
    -- mob repops: we see it alive again -> re-arm
    eq(t:observe(1, false, 20), nil, 'alive observation re-arms')
    -- dies again
    eq(t:observe(1, true, 30), 'died', 'second death registered after re-arm')
    eq(t:rows(30)[1].text, '0:10', 'fresh countdown')
end

print('kill during pop phase restarts the timer (regression)')
do
    local t = Tracker.new({ popDuration = 5 })
    t:track(1, { respawn = 10 })
    t:observe(1, true, 0)                 -- dies
    t:update(10)                          -- countdown expires -> pop
    eq(t:rows(11)[1].state, 'pop', 'in pop phase, line still present')
    -- mob has already repopped in the world while we show "pop"; we see it alive
    eq(t:observe(1, false, 11), nil, 're-arms during pop phase')
    -- and is killed again before the pop line clears
    eq(t:observe(1, true, 12), 'died', 'fresh death registered during pop phase')
    local r = t:rows(12)[1]
    eq(r.state, 'dead', 'pop replaced by a new countdown')
    eq(r.text, '0:10', 'new full countdown from the new death')
end

print('death with no respawn time -> unknown, then setRespawn starts it')
do
    local t = Tracker.new()  -- no default respawn
    t:track(2, {})
    t:observe(2, true, 100)
    local r = t:rows(100)[1]
    eq(r.state, 'unknown', 'unknown state when no time')
    eq(r.text, '--:--', 'placeholder text')
    -- now provide a time; countdown should compute from the death time (100)
    check(t:setRespawn(2, 30), 'setRespawn ok')
    eq(t:rows(105)[1].state, 'dead', 'becomes a real countdown')
    eq(t:rows(105)[1].text, '0:25', 'computed from diedAt + respawn - now')
end

print('defaultRespawn applies when mob has none')
do
    local t = Tracker.new({ defaultRespawn = 60 })
    t:track(3, {})
    t:observe(3, true, 0)
    eq(t:rows(0)[1].text, '1:00', 'uses default respawn')
end

------------------------------------------------------------------------------
print('rows ordering and slot resolution')
do
    local t = Tracker.new()
    t:track(10, { respawn = 100 })
    t:track(20, { respawn = 100 })
    t:track(30, { respawn = 100 })
    t:observe(20, true, 0)
    t:observe(30, true, 0)
    local rows = t:rows(0)
    eq(#rows, 2, 'only dead mobs have rows')
    eq(rows[1].serverId, 20, 'rows follow track order (20 before 30)')
    eq(rows[1].slot, 1, 'slot 1')
    eq(rows[2].slot, 2, 'slot 2')
    eq(t:serverIdBySlot(1, 0), 20, 'slot 1 -> serverId 20')
    eq(t:serverIdBySlot(2, 0), 30, 'slot 2 -> serverId 30')
    eq(t:serverIdBySlot(3, 0), nil, 'out of range slot -> nil')
end

print('untrackAll')
do
    local t = Tracker.new()
    t:track(1, {}); t:track(2, {})
    t:observe(1, true, 0)
    t:untrackAll()
    eq(t:count(), 0, 'count 0 after untrackAll')
    eq(#t:rows(0), 0, 'no rows after untrackAll')
end

print('export / import watch (persistence round-trip)')
do
    local t = Tracker.new()
    t:track(111, { mobName = 'Leech', respawn = 240 })
    t:rename(111, 'East Leech')
    t:track(222, { mobName = 'Crab' })
    t:observe(111, true, 0)  -- transient timer must NOT be exported
    local dump = t:exportWatch()
    check(dump['111'] ~= nil, 'exported by string key')
    eq(dump['111'].name, 'East Leech', 'exports custom name')
    eq(dump['111'].respawn, 240, 'exports respawn')
    check(dump['111'].diedAt == nil, 'does not export transient timer fields')

    local t2 = Tracker.new()
    t2:importWatch(dump)
    eq(t2:count(), 2, 'imported both')
    eq(t2:label(111), 'East Leech', 'name survived round-trip')
    eq(t2.watch[111].respawn, 240, 'respawn survived round-trip')
    eq(#t2:rows(0), 0, 'no active timers after import')
end

print('imported mobs start disarmed: a corpse on load is not a fresh kill')
do
    -- Simulate addon load: watch list restored from settings.
    local t = Tracker.new()
    t:importWatch({ ['500'] = { mobName = 'NM', respawn = 60 } })
    -- First poll after load sees the mob ALREADY dead (corpse in the area).
    eq(t:observe(500, true, 0), nil, 'dead-at-load does NOT start a timer')
    eq(#t:rows(0), 0, 'no timer line on load')
    -- Mob repops; we see it alive -> now armed.
    eq(t:observe(500, false, 30), nil, 'seeing it alive arms it')
    -- Now an actual witnessed kill starts the timer.
    eq(t:observe(500, true, 40), 'died', 'witnessed kill after load starts timer')
    eq(t:rows(40)[1].text, '1:00', 'fresh countdown')
end

print('/track arms immediately (you can only target a live mob)')
do
    local t = Tracker.new()
    t:track(600, { mobName = 'Worm', respawn = 30 })  -- default armed=true
    eq(t:observe(600, true, 0), 'died', 'tracked mob death registers right away')
end

------------------------------------------------------------------------------
if failures == 0 then
    print(('\nAll %d checks passed.'):format(tests))
    os.exit(0)
else
    print(('\n%d/%d checks FAILED.'):format(failures, tests))
    os.exit(1)
end
