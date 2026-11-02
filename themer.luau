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

-- Settings that actually change the palette (or the frame it is built from).
-- interval / notify_errors / run_on_start must not trigger a matugen run:
-- dragging the interval slider used to regenerate the whole palette each step.
local function paletteKey()
  return table.concat({
    table.concat(M.args(""), "\0"),
    tostring(noctalia.getConfig("shell_wallpaper")),
    tostring(noctalia.getConfig("video_mode")),
    tostring(noctalia.getConfig("ffmpeg_path")),
    tostring(noctalia.getConfig("frame_offset")),
    tostring(noctalia.getConfig("frame_width")),
    tostring(noctalia.getConfig("assignments_file")),
  }, "\1")
end

local last_palette_key = paletteKey()

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

  -- Forget outputs that are gone. A monitor that reconnects (or an output
  -- whose sampled frame was hidden for a while) is then a fresh source instead
  -- of being compared against a stale path.
  for connector in pairs(last_source) do
    if sources[connector] == nil then last_source[connector] = nil end
  end

  if next(sources) == nil then
    -- No outputs yet (or none with a wallpaper): nothing to compare, and the
    -- service must not seed itself on an empty state.
    return
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
    for connector, source in pairs(sources) do
      last_source[connector] = source
      count = count + 1
    end
    noctalia.log("matugen: watching " .. tostring(count) .. " output(s)")
    if noctalia.getConfig("run_on_start") ~= false then
      regenerate(M.targetWallpaper(), false)
    end
    return
  end

  -- A request refused because another entry held the lock is retried once it
  -- clears. While it is still busy, do not pile up more work.
  if pending ~= nil then
    if M.busy() then return end
    local source = pending
    pending = nil
    noctalia.log("matugen: retrying deferred source -> " .. source)
    regenerate(source, false)
    return
  end

  -- Compare every output, then apply one source per tick: matugen only makes
  -- one palette anyway. Outputs that lost the selection stay stale on purpose
  -- and are picked up on a later tick. The focused output wins ties, so the
  -- choice does not depend on pairs() order.
  local changed = {}
  for connector, source in pairs(sources) do
    local previous = last_source[connector]
    if previous == nil or previous ~= source then
      changed[connector] = source
    end
  end

  local chosen_source = nil
  if next(changed) ~= nil then
    local connectors = {}
    for connector in pairs(changed) do connectors[#connectors + 1] = connector end
    table.sort(connectors)
    local chosen_connector = connectors[1]
    local focused = noctalia.focusedOutputName()
    if focused ~= nil and changed[focused] ~= nil then
      chosen_connector = focused
    end
    chosen_source = changed[chosen_connector]

    -- Outputs already showing the chosen source are up to date too, so a
    -- wallpaper shared by several outputs does not trigger a duplicate run.
    for connector, source in pairs(sources) do
      if source == chosen_source then last_source[connector] = source end
    end
  else
    for connector, source in pairs(sources) do last_source[connector] = source end
  end

  if chosen_source ~= nil then
    noctalia.log("matugen: source changed -> " .. chosen_source)
    regenerate(chosen_source, false)
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

  local key = paletteKey()
  local palette_changed = key ~= last_palette_key
  last_palette_key = key

  seeded = true
  last_mode = M.mode()

  if palette_changed then
    -- Only seed on the very first config event: after that, last_source must
    -- keep tracking outputs so a wallpaper change is not swallowed.
    if next(last_source) == nil then
      for connector, source in pairs(M.sources()) do
        last_source[connector] = source
      end
    end
    noctalia.log("matugen: settings changed, regenerating")
    regenerate(M.targetWallpaper(), false)
  end
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
  -- Return only this entry's lock so a later run is not blocked by a request
  -- that died with this runtime; never unlock a run started by another entry.
  M.releaseLock()
  noctalia.log("matugen: service stopped (" .. tostring(reason) .. ")")
end
