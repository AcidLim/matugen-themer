--!nonstrict
-- Matugen Themer - control-center [[shortcut]] entry.
--
-- Regenerates the palette on demand, which is what you want after editing the
-- Matugen templates (bindings) by hand: the wallpaper did not change, so the
-- service has nothing to react to.

local M = require("./matugen.luau")

local busy = false
local phase = "idle"

local function render()
  if busy then
    local label = noctalia.tr("shortcut.refresh.busy")
    if phase == "extracting" then
      label = noctalia.tr("shortcut.refresh.sampling")
    end
    shortcut.setLabel(label)
    shortcut.setIcon("loader")
    shortcut.setActive(true)
    -- Stay clickable. A shortcut has no update() timer, so if the run callback
    -- is lost the tile would otherwise stay disabled until the lock TTL expires;
    -- clicking again just shows the "busy" toast.
  else
    shortcut.setLabel(noctalia.tr("shortcut.refresh.label"))
    shortcut.setIcon("palette")
    shortcut.setActive(false)
    shortcut.setEnabled(true)
  end
end

-- The busy lock and the phase live in noctalia.state, so the tile greys out for
-- runs started by the service as well.
local function sync()
  local now_busy = M.busy()
  local now_phase = noctalia.state.get("phase") or "idle"
  if now_busy ~= busy or now_phase ~= phase then
    busy = now_busy
    phase = now_phase
    render()
  end
end

render()

noctalia.state.watch("busy_until", sync)
noctalia.state.watch("phase", sync)
-- A run may already be in flight when this entry loads (the control center is
-- opened mid-regeneration); pick that state up instead of showing "idle".
sync()

local function refresh()
  M.run(M.targetWallpaper(), {
    announce = true,
    onDone = function(succeeded)
      sync()
      if succeeded then
        noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.done"))
      end
    end,
  })
  -- A request that never started (no wallpaper, missing binary, folder source,
  -- video sampling turned off) has already been announced; just re-read the
  -- real lock state.
  sync()
end

function onClick()
  refresh()
end

function onRightClick()
  noctalia.openSettings()
end

function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

function onExit(_signal, reason)
  -- A run started from this tile may still be in flight when the control center
  -- reloads the shortcut; its callback is discarded with this VM, so do not let
  -- the service wait on this entry's lock until the TTL expires.
  M.releaseLock()
  noctalia.log("matugen: refresh tile stopped (" .. tostring(reason) .. ")")
end

function onConfigChanged()
  -- Labels follow the shell language, so re-render after a settings change.
  render()
end
