addon.name    = 'pop-tracker'
addon.author  = 'paul'
addon.version = '1.0'
addon.desc    = 'Track watched mobs and time their respawns after they die.'

require('common')
local imgui    = require('imgui')
local settings = require('settings')
local Tracker  = require('tracker')

--[[
    pop-tracker
    -----------
    /track [time] [name]     track current target.  time is mm:ss or seconds;
                             anything after (or instead) is an optional name.
    /untrack [slot|all]      untrack current target, a window slot, or everything.
    /poptracker (alias /pt):
        rename [slot] <name> rename current target, or a window slot, to <name>.
        settime [slot] <t>   set/replace respawn time for target or a slot.
        show | hide | toggle window visibility.
        showall              toggle showing alive watched mobs too.
        list                 print the watch list to chat.
        debug                toggle verbose status/death logging.
        help                 show command help.

    Respawn time note: FFXI does NOT send mob respawn times to the client, so
    there is nothing to "read" -- give a time on /track (or /settime), or set a
    default with /pt default <time>.  Until a time is known the line shows --:--.
]]

------------------------------------------------------------------------------
-- state
------------------------------------------------------------------------------

local default_settings = T{
    visible        = true,
    showall        = false,   -- also list alive watched mobs in the window
    opacity        = 0.35,    -- window background alpha (transparent)
    defaultRespawn = 0,       -- 0 = none; otherwise seconds applied when no time given
    watch          = T{},     -- [tostring(serverId)] = T{ name=, mobName=, respawn= }
}

local cfg      -- loaded settings table
local tracker  -- Tracker instance
local pt = {
    debug = false,
    -- entity status values treated as "dead".  Standard FF/Ashita values are
    -- 2 and 3; configurable here in case your server differs (use /pt debug to
    -- confirm in-game, then tell me if these need changing).
    death_status = { [2] = true, [3] = true },
    last_status  = {},  -- [serverId] = last seen status, for debug logging
    window_open  = { true },
}

------------------------------------------------------------------------------
-- chat helpers
------------------------------------------------------------------------------

local function chat(msg)
    print(('\30\03[\30\05pop-tracker\30\03] \30\01%s'):format(msg))
end

local function debugf(fmt, ...)
    if pt.debug then chat('[debug] ' .. fmt:format(...)) end
end

------------------------------------------------------------------------------
-- game accessors (the only Ashita-coupled code; kept thin & guarded)
------------------------------------------------------------------------------

-- Returns the entity index of the current target, or nil if there is no target.
local function get_target_index()
    local mgr = AshitaCore:GetMemoryManager()
    local target = mgr:GetTarget()
    if not target then return nil end
    local idx = target:GetTargetIndex(0)
    if not idx or idx == 0 then return nil end
    return idx
end

local function entity()
    return AshitaCore:GetMemoryManager():GetEntity()
end

-- Read identity/status for an entity index.  Returns serverId, name, status.
local function read_entity(index)
    local e = entity()
    if not e then return nil end
    local serverId = e:GetServerId(index)
    if not serverId or serverId == 0 then return nil end
    return serverId, e:GetName(index), e:GetStatus(index)
end

-- Re-find the live entity index for a serverId we are watching (its index can
-- change after a repop).  Verifies the cached index first, then scans.
local function find_index(serverId, cachedIndex)
    local e = entity()
    if not e then return nil end
    if cachedIndex and e:GetServerId(cachedIndex) == serverId then
        return cachedIndex
    end
    -- Scan the local-spawn range; mobs live below 0x700 (1792).
    for i = 1, 0x6FF do
        if e:GetServerId(i) == serverId then return i end
    end
    return nil
end

------------------------------------------------------------------------------
-- persistence
------------------------------------------------------------------------------

local function persist_watch()
    cfg.watch = T(tracker:exportWatch())
    settings.save()
end

------------------------------------------------------------------------------
-- command handling
------------------------------------------------------------------------------

local function print_help()
    chat('commands:')
    chat('  /track [mm:ss|secs] [name] - watch target (optional time, then optional name)')
    chat('  /untrack [slot|all]      - stop watching target / a slot / everything')
    chat('  /pt rename [slot] <name> - rename current target or a window slot')
    chat('  /pt settime [slot] <t>   - set respawn time for target or a slot')
    chat('  /pt default <t>          - default respawn when none given (0=off)')
    chat('  /pt show|hide|toggle     - window visibility')
    chat('  /pt showall              - also show alive watched mobs')
    chat('  /pt list                 - print the watch list')
    chat('  /pt debug                - toggle status/death logging')
end

-- /track [time] [name...]
local function cmd_track(args)
    local idx = get_target_index()
    if not idx then chat('No target. Select a mob, then /track.'); return end
    local serverId, mobName, status = read_entity(idx)
    if not serverId then chat('Could not read target entity.'); return end

    -- A leading token that parses as a time is the respawn; everything after it
    -- (or everything from arg 2 if there's no time) is the optional custom name.
    local respawn, nameStart
    if args[2] and Tracker.parseTime(args[2]) then
        respawn, nameStart = Tracker.parseTime(args[2]), 3
    else
        nameStart = 2
    end
    local name = table.concat(args, ' ', nameStart)
    if name == '' then name = nil end

    local isNew = tracker:track(serverId, {
        mobName = mobName,
        index   = idx,
        respawn = respawn,
        name    = name,
    })
    pt.last_status[serverId] = status
    persist_watch()
    debugf('track id=%d idx=%d status=%s mob=%s name=%s',
        serverId, idx, tostring(status), tostring(mobName), tostring(name))
    chat(('%s "%s" (id %d)%s'):format(
        isNew and 'Tracking' or 'Updated',
        tracker:label(serverId), serverId,
        respawn and (' respawn ' .. Tracker.formatClock(respawn)) or ''))
end

-- Resolve a target serverId for a command that optionally takes a leading slot.
-- Returns serverId, firstValueArgIndex.  Uses the current target when no slot.
local function resolve_target(args, valueStart)
    local now = os.clock()
    local maybeSlot = tonumber(args[valueStart])
    if maybeSlot and maybeSlot == math.floor(maybeSlot) then
        local id = tracker:serverIdBySlot(maybeSlot, now)
        if id then return id, valueStart + 1 end
    end
    -- fall back to current target
    local idx = get_target_index()
    if idx then
        local serverId = read_entity(idx)
        if serverId and tracker:isTracked(serverId) then
            return serverId, valueStart
        end
        if serverId then return nil, valueStart, 'nottracked' end
    end
    return nil, valueStart, 'notarget'
end

-- /untrack [slot|all]
local function cmd_untrack(args)
    if args[2] and args[2]:lower() == 'all' then
        tracker:untrackAll()
        persist_watch()
        chat('Untracked everything.')
        return
    end
    local id = resolve_target(args, 2)
    if not id then chat('Target a tracked mob or give a slot number.'); return end
    local label = tracker:label(id)
    tracker:untrack(id)
    pt.last_status[id] = nil
    persist_watch()
    chat(('Untracked "%s" (id %d).'):format(label, id))
end

-- /pt rename [slot] <name...>
local function cmd_rename(args)
    local id, valueIdx, err = resolve_target(args, 2)
    if not id then
        chat(err == 'nottracked' and 'Target is not tracked.'
            or 'Target a tracked mob (or give a slot) then /pt rename <name>.')
        return
    end
    local name = table.concat(args, ' ', valueIdx)
    if name == '' then chat('Usage: /pt rename [slot] <name>'); return end
    tracker:rename(id, name)
    persist_watch()
    chat(('Renamed id %d to "%s".'):format(id, name))
end

-- /pt settime [slot] <time>
local function cmd_settime(args)
    local id, valueIdx, err = resolve_target(args, 2)
    if not id then
        chat(err == 'nottracked' and 'Target is not tracked.'
            or 'Target a tracked mob (or give a slot) then /pt settime <time>.')
        return
    end
    local secs = Tracker.parseTime(args[valueIdx])
    if not secs then chat('Usage: /pt settime [slot] <mm:ss|seconds>'); return end
    tracker:setRespawn(id, secs)
    persist_watch()
    chat(('Set respawn for "%s" to %s.'):format(tracker:label(id), Tracker.formatClock(secs)))
end

local function cmd_list()
    if tracker:count() == 0 then chat('Watch list is empty.'); return end
    chat(('Watch list (%d):'):format(tracker:count()))
    for _, id in ipairs(tracker.order) do
        local w = tracker.watch[id]
        chat(('  id %d  "%s"  respawn %s'):format(
            id, tracker:label(id),
            w.respawn and Tracker.formatClock(w.respawn) or '(none)'))
    end
end

local function handle_command(e)
    local args = e.command:args()
    if #args == 0 then return end
    local c = args[1]:lower()

    if c == '/track' then
        cmd_track(args); e.blocked = true; return
    elseif c == '/untrack' then
        cmd_untrack(args); e.blocked = true; return
    elseif c == '/poptracker' or c == '/pt' then
        local sub = (args[2] or 'help'):lower()
        if sub == 'rename' then cmd_rename(args)
        elseif sub == 'settime' then cmd_settime(args)
        elseif sub == 'default' then
            local s = Tracker.parseTime(args[3]) or 0
            cfg.defaultRespawn = s
            tracker.defaultRespawn = (s > 0) and s or nil
            settings.save()
            chat(('Default respawn %s.'):format(s > 0 and Tracker.formatClock(s) or 'disabled'))
        elseif sub == 'show' then cfg.visible = true; pt.window_open[1] = true
        elseif sub == 'hide' then cfg.visible = false
        elseif sub == 'toggle' then cfg.visible = not cfg.visible; pt.window_open[1] = cfg.visible
        elseif sub == 'showall' then
            cfg.showall = not cfg.showall
            chat(('Show alive watched mobs: %s.'):format(cfg.showall and 'on' or 'off'))
        elseif sub == 'list' then cmd_list()
        elseif sub == 'debug' then
            pt.debug = not pt.debug
            chat(('Debug logging %s.'):format(pt.debug and 'on' or 'off'))
        else print_help() end
        e.blocked = true
        return
    end
end

------------------------------------------------------------------------------
-- per-frame: death detection + rendering
------------------------------------------------------------------------------

-- Poll the status of each watched, currently-alive mob and feed liveness to the
-- tracker so deaths are caught whether we or someone else lands the kill.
local function poll_deaths(now)
    local e = entity()
    if not e then return end
    for _, serverId in ipairs(tracker.order) do
        local w = tracker.watch[serverId]
        -- Only need to watch mobs that aren't already counting down.
        if not tracker.timers[serverId] then
            local idx = find_index(serverId, w.index)
            if idx then
                w.index = idx
                local status = e:GetStatus(idx)
                if pt.debug and pt.last_status[serverId] ~= status then
                    debugf('id=%d idx=%d status %s -> %s', serverId, idx,
                        tostring(pt.last_status[serverId]), tostring(status))
                end
                pt.last_status[serverId] = status
                local isDead = pt.death_status[status] == true
                if tracker:observe(serverId, isDead, now) == 'died' then
                    chat(('"%s" defeated -> respawn timer started.'):format(tracker:label(serverId)))
                end
            end
            -- If idx is nil the mob is out of render range; we simply can't see
            -- it die right now, which matches "as long as I can see it defeated".
        end
    end
end

local function render(now)
    if not cfg.visible then return end

    imgui.SetNextWindowBgAlpha(cfg.opacity)
    imgui.SetNextWindowSize({ 200, 0 }, ImGuiCond_FirstUseEver)
    pt.window_open[1] = cfg.visible
    -- Stable ###id so the visible title can change without resetting position.
    if imgui.Begin(('Pop Tracker###poptracker'), pt.window_open, ImGuiWindowFlags_AlwaysAutoResize) then
        local rows = tracker:rows(now)
        if #rows == 0 then
            imgui.TextDisabled('(no active timers)')
        else
            for _, r in ipairs(rows) do
                if r.state == 'pop' then
                    imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, ('[%d] %s: pop'):format(r.slot, r.label))
                elseif r.state == 'unknown' then
                    imgui.TextColored({ 1.0, 0.8, 0.3, 1.0 }, ('[%d] %s: --:-- (set time)'):format(r.slot, r.label))
                else
                    imgui.Text(('[%d] %s: %s'):format(r.slot, r.label, r.text))
                end
            end
        end
        if cfg.showall then
            imgui.Separator()
            for _, id in ipairs(tracker.order) do
                if not tracker.timers[id] then
                    imgui.TextDisabled(('%s: up'):format(tracker:label(id)))
                end
            end
        end
    end
    imgui.End()

    -- If the user closed the window via its [x], remember that.
    if not pt.window_open[1] then cfg.visible = false end
end

------------------------------------------------------------------------------
-- events
------------------------------------------------------------------------------

ashita.events.register('load', 'pt_load', function()
    cfg = settings.load(default_settings)
    tracker = Tracker.new({ defaultRespawn = cfg.defaultRespawn })
    tracker:importWatch(cfg.watch)
    chat(('loaded. tracking %d mob(s). /pt help for commands.'):format(tracker:count()))
end)

ashita.events.register('command', 'pt_command', function(e)
    handle_command(e)
end)

ashita.events.register('d3d_present', 'pt_present', function()
    if not tracker then return end
    local now = os.clock()
    poll_deaths(now)
    tracker:update(now)
    render(now)
end)

ashita.events.register('unload', 'pt_unload', function()
    if tracker then persist_watch() end
end)

-- Re-save when settings.lua reloads the file (e.g. external edit).
settings.register('settings', 'pt_settings_update', function(s)
    if s then cfg = s end
end)
