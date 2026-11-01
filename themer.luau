--!nonstrict
-- Matugen Themer - headless [[service]] entry.
--
-- The old setup relied on a [hooks] wallpaper_changed shell script. Noctalia v5
-- exposes no wallpaper-change event, so this service does the equivalent by
-- polling: once per tick it compares the current visual source of every output
-- (the mpvpaper video when one owns the output, otherwise Noctalia's wallpaper
-- path) and, in `auto` mode, the shell's light/dark state against the last seen
-- values, then regenerates the palette when either moves.

local M = require("./matugen.luau")

local last_source = {}      -- connector -> last seen wallpaper or video path
local last_mode = nil
local seeded = false
local pending = nil         -- source that could not start because a run was busy

local function interval()
  local ms = tonumber(noctalia.getConfig("interval")) or 1000
  if ms < 250 then ms = 250 end
  if ms > 10000 then ms = 10000 end
  return ms
end

local function applyInterval()
  noctalia.setUpdateInterval(interval())
end

applyInterval()

-- A run refused because another one is in flight is retried on the next tick
-- instead of being dropped, so fast wallpaper switching still ends on the last
-- image.
local function regenerate(source, announce)
  if source == nil or source == "" then
    if announce then
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.no_wallpaper"))
    end
    return
  end
  local ok, reason = M.run(source, { announce = announce })
  if not ok and reason == "busy" then pending = source end
end

local function poll()
  local sources = M.sources()
  if next(sources) == nil then
    -- No outputs yet (or none with a wallpaper): nothing to compare, and the
    -- service must not seed itself on an empty state.
    return
  end
  if pending ~= nil and not M.busy() then
    local source = pending
    pending = nil
    noctalia.log("matugen: retrying deferred source -> " .. source)
    regenerate(source, false)
    return
  end

  -- Note the last source that actually moved; one regeneration per tick.
  local changed = nil
  local seen = {}
  for connector, source in pairs(sources) do
    local previous = last_source[connector]
    if previous == nil then
      -- A newly connected output (or the first wallpaper after a session with
      -- none) counts as a change; the seeding tick itself passes here with
      -- seeded still false.
      if seeded then changed = source end
    elseif previous ~= source and not seen[source] then
      changed = source
      seen[source] = true
    end
    last_source[connector] = source
  end

  local mode = M.mode()
  local mode_changed = last_mode ~= nil and last_mode ~= mode
  last_mode = mode

  if not seeded then
    -- First tick only records the current state. `run_on_start` opts into
    -- applying the current settings right away instead of waiting for the next
    -- wallpaper change.
    seeded = true
    local count = 0
    for _ in pairs(sources) do count = count + 1 end
    noctalia.log("matugen: watching " .. tostring(count) .. " output(s)")
    if noctalia.getConfig("run_on_start") ~= false then
      regenerate(M.targetWallpaper(), false)
    end
    return
  end

  if changed ~= nil then
    noctalia.log("matugen: source changed -> " .. changed)
    regenerate(changed, false)
  elseif mode_changed then
    -- Only reachable with mode = "auto": the shell flipped light/dark.
    noctalia.log("matugen: shell mode changed -> " .. mode)
    regenerate(M.targetWallpaper(), false)
  end
end

function update()
  poll()
end

-- Noctalia keeps this service alive across a settings change when
-- onConfigChanged() exists, so a new scheme/contrast is applied immediately
-- rather than after the next wallpaper change (a restart alone would not
-- regenerate anything, since the watcher would just re-seed).
function onConfigChanged()
  applyInterval()
  seeded = true
  last_mode = M.mode()
  noctalia.log("matugen: settings changed, regenerating")
  regenerate(M.targetWallpaper(), false)
end

function onIpc(event, payload)
  if event == "refresh" then
    regenerate(M.targetWallpaper(), true)
  elseif event == "status" then
    local status = M.status()
    local text = status.running and "running" or status.phase
    if status.image ~= "" then
      text = text .. ": " .. status.image
      if status.frame ~= "" and status.frame ~= status.image then
        text = text .. " -> " .. status.frame
      end
    end
    if status.error ~= "" then text = text .. " (" .. status.error .. ")" end
    noctalia.notify(noctalia.tr("toast.title"), text)
  else
    noctalia.log("matugen: unknown IPC event '" .. tostring(event) .. "'")
  end
end

function onExit(_signal, reason)
  -- Return the lock so a later run is not blocked by a request that died with
  -- this runtime.
  noctalia.state.set("busy_until", 0)
  noctalia.log("matugen: service stopped (" .. tostring(reason) .. ")")
end
