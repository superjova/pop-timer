# pop-tracker

An Ashita v4 addon for FFXI (HorizonXI, 75-cap era) that watches mobs you
choose and counts down their respawn after they die — yours or anyone's kill,
as long as you can see the mob get defeated.

## Install

Copy the `pop-tracker` folder into `Ashita4/addons/`, then in-game:

```
/addon load pop-tracker
```

(Use `/addon`, not `/plugin` — `/plugin` is for compiled DLLs.)

## Commands

| Command | What it does |
| --- | --- |
| `/track [mm:ss\|secs] [name]` | Watch the current target. Optional respawn time then optional name, e.g. `/track 5:50 North Sheep`, `/track 350`, or `/track North Sheep`. |
| `/untrack [slot\|all]` | Stop watching the current target, a window slot number, or everything. |
| `/pt rename [slot] <name>` | Rename the current target (or a slot) — e.g. `/pt rename North Sheep`. |
| `/pt settime [slot] <t>` | Set/replace the respawn time for the target or a slot. |
| `/pt default <t>` | Default respawn used when `/track` is given no time (`0` = off). |
| `/pt show \| hide \| toggle` | Window visibility. |
| `/pt showall` | Also list alive watched mobs (dimmed) in the window. |
| `/pt list` | Print the full watch list to chat. |
| `/pt debug` | Toggle verbose status/death logging (see "Tuning" below). |
| `/pt help` | Command help. |

`slot` is the `[n]` number shown at the start of each window line, so you can
rename/untrack a mob that has already died (and can't be targeted).

## How it behaves

- **Watch list is persistent.** A mob stays tracked until `/untrack`. The names
  and respawn times you set are saved to `config/settings.lua` and restored on
  load.
- **The window is headerless and always on.** There's no title bar and no
  toggle to fiddle with: the transparent, draggable window simply isn't drawn
  while there's nothing to show, and appears on its own the moment a tracked mob
  dies (showing `[n] <label>: <countdown>`). Drag the body to move it; its
  position persists via `imgui.ini`. (`/pt hide` is a master off-switch if you
  ever want it gone entirely.)
- **Pop.** When the countdown hits zero the line shows `pop` (green) for ~5
  seconds, then the line disappears — but the mob is **still tracked**, so the
  next time it dies a fresh timer line appears. Killing it again *during* the
  countdown or pop phase (e.g. it repopped faster than your set time) restarts
  the timer from the new death.
- **Label.** Defaults to the mob's server ID (so you can tell apart three
  identical "Sheep"). Rename it to whatever you like.
- **No target = nothing happens** on `/track`.
- **Only witnessed kills start a timer.** A timer begins on an actual
  alive→dead transition the addon sees. On load, your saved watch list is
  restored *disarmed*: a mob must be seen alive before its death counts, so a
  corpse already lying in the zone when you load the addon is **not** mistaken
  for a fresh kill.

## Respawn times — important / honest note

FFXI does **not** send mob respawn times to the client. There is no packet to
read, so this is **not** something the addon can auto-detect — you supply the
time on `/track` (or later with `/pt settime`, or a `/pt default`). Until a time
is known, a dead mob's line shows `--:-- (set time)` and won't count down; set a
time and it computes from the moment it died.

## Tuning death detection (one-line in-game capture)

Death is detected from the mob's **entity status**. The standard values treated
as "dead" are `2` and `3`, which is correct on retail-like servers, but private
servers can differ. To confirm on HorizonXI:

1. `/pt debug`
2. `/track` a mob, then watch it die.
3. Read the logged lines, e.g. `id=… status 1 -> 3` — the value it lands on at
   death is the death status.

If yours differs from `{2, 3}`, tell me and I'll adjust `pt.death_status` in
`pop-tracker.lua` (or we can make it a setting).

## Development

Pure logic lives in `tracker.lua` (no Ashita dependencies) and is covered by
offline unit tests. The game wiring is in `pop-tracker.lua`.

```
lua5.1 test/run.lua          # run unit tests (luajit also works)
luac5.1 -p *.lua test/*.lua  # syntax gate
```
