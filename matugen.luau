--!nonstrict
-- Shared Matugen plumbing for the Matugen Themer plugin.
--
-- `themer.luau` (service) and `refresh.luau` (shortcut) both require() this
-- module, so the command line is assembled in exactly one place. It also owns
-- the busy lock: every entry runs in its own Luau VM, so the only thing they
-- can share is noctalia.state.
--
-- A video wallpaper never reaches matugen directly: the source is sampled into
-- a cached JPEG first (see video.luau), and the palette is built from that.

local U = require("./util.luau")
local video = require("./video.luau")

local M = {}

-- A run that never reports back (crash, killed process) must not wedge the
-- plugin forever, so the lock carries an expiry instead of a plain flag. The
-- TTL is refreshed when extraction ends and again before matugen starts; it is
-- only a fallback for a runtime that died without running onExit().
local BUSY_TTL_MS = 300000

-- The lock lives in noctalia.state and is shared by every entry, but only the
-- entry that took it may release it: a reloading service must not unlock a run
-- that the control-center tile started (and vice versa).
local OWNER = tostring({}) .. ":" .. tostring(noctalia.nowMs())

local running = false     -- this VM only
local queued_path = nil
local queued_opts = nil

local function cfg(key, fallback)
  return U.cfg(key, fallback)
end

--- Expand a leading `~` only; bare command names stay bare.
function M.expand(path)
  return U.expand(path)
end

function M.isVideo(path)
  return video.isVideo(path)
end

--- Configured matugen executable, with `~` expanded.
function M.binary()
  return M.expand(tostring(cfg("matugen_path", "matugen")))
end

function M.binaryAvailable(bin)
  if bin == nil or bin == "" then return false end
  -- An absolute/relative path is checked directly; a bare name is looked up
  -- on $PATH.
  if string.find(bin, "/", 1, true) ~= nil then
    return noctalia.fileExists(bin)
  end
  return noctalia.commandExists(bin)
end

--- Resolved Matugen mode: "auto" follows the shell's current light/dark state.
function M.mode()
  local mode = tostring(cfg("mode", "dark"))
  if mode == "auto" then
    if noctalia.isDarkMode ~= nil and noctalia.isDarkMode() then return "dark" end
    return "light"
  end
  if mode == "light" then return "light" end
  return "dark"
end

--- Visual source of one output: the mpvpaper video when that output is driven
--- by a video, otherwise Noctalia's own wallpaper path.
function M.sourceFor(connector, assigned)
  if assigned ~= nil then
    -- mpvpaper stores a per-output path or the "*" wildcard for "all outputs".
    local path = assigned[connector] or assigned["*"]
    if path ~= nil and noctalia.fileExists(path) then return path end
  end
  local wp = noctalia.wallpaperPath(connector)
  if wp == nil or wp == "" then return nil end
  -- Our own sampled frame is not a wallpaper; ignoring it keeps the watcher
  -- from reacting to its own handoff.
  if video.isFrame(wp) then return nil end
  return wp
end

--- connector -> current visual source (a video when that output runs one),
--- for every output that has one.
function M.sources()
  local assigned = video.assignments()
  local map = {}
  local outputs = noctalia.outputs()
  if outputs == nil then return map end
  for _, output in ipairs(outputs) do
    local source = M.sourceFor(output.name, assigned)
    if source ~= nil then map[output.name] = source end
  end
  return map
end

--- The wallpaper the shell is currently showing on the focused output,
--- falling back to the first output that has one.
function M.targetWallpaper(assigned)
  assigned = assigned or video.assignments()
  local name = noctalia.focusedOutputName()
  if name ~= nil then
    local source = M.sourceFor(name, assigned)
    if source ~= nil then return source end
  end
  local outputs = noctalia.outputs()
  if outputs ~= nil then
    for _, output in ipairs(outputs) do
      local source = M.sourceFor(output.name, assigned)
      if source ~= nil then return source end
    end
  end
  return nil
end

--- Full argv for one regeneration. Argument-array form (plugin_api 24) means
--- paths with spaces and quotes need no shell escaping.
function M.args(image)
  local argv = { M.binary() }

  local conf = M.expand(tostring(cfg("config_file", "")))
  if conf ~= "" then
    argv[#argv + 1] = "--config"
    argv[#argv + 1] = conf
  end

  argv[#argv + 1] = "image"
  argv[#argv + 1] = image
  argv[#argv + 1] = "--type"
  argv[#argv + 1] = tostring(cfg("type", "scheme-tonal-spot"))
  argv[#argv + 1] = "--mode"
  argv[#argv + 1] = M.mode()
  argv[#argv + 1] = "--prefer"
  argv[#argv + 1] = tostring(cfg("prefer", "saturation"))
  argv[#argv + 1] = "--source-color-index"
  argv[#argv + 1] = tostring(math.floor(tonumber(cfg("source_index", 0)) or 0))
  argv[#argv + 1] = "--contrast"
  argv[#argv + 1] = tostring(tonumber(cfg("contrast", 0)) or 0)

  local extra = noctalia.getConfig("extra_args")
  if type(extra) == "table" then
    for _, arg in ipairs(extra) do
      if U.trim(arg) ~= "" then argv[#argv + 1] = tostring(arg) end
    end
  end

  return argv
end

--- True while a regeneration (or its frame extraction) is in flight, in any
--- entry of this plugin.
function M.busy()
  local until_ms = tonumber(noctalia.state.get("busy_until"))
  if until_ms == nil then return false end
  return noctalia.nowMs() < until_ms
end

local function lock()
  noctalia.state.set("busy_until", noctalia.nowMs() + BUSY_TTL_MS)
  noctalia.state.set("busy_owner", OWNER)
end

local function unlock()
  local owner = noctalia.state.get("busy_owner")
  -- nil means a lock left by an older runtime that did not record an owner;
  -- only an owner that is explicitly someone else is protected.
  if owner ~= nil and owner ~= OWNER then return end
  noctalia.state.set("busy_until", 0)
  noctalia.state.set("busy_owner", "")
end

--- Release this entry's lock. Called from service onExit: another entry's run
--- must keep its lock when this runtime is reloaded or disabled.
function M.releaseLock()
  unlock()
end

--- Publish run status as flat scalars: noctalia.state only promises plain
--- values, and both entries read it back.
local function publish(phase, source, err, frame)
  noctalia.state.set("phase", phase)
  noctalia.state.set("last_image", source or "")
  noctalia.state.set("last_frame", frame or "")
  noctalia.state.set("last_error", err or "")
  noctalia.state.set("last_at", noctalia.nowMs())
end

--- Last known status, for the shortcut tile and the `status` IPC event.
function M.status()
  return {
    phase = noctalia.state.get("phase") or "idle",
    image = noctalia.state.get("last_image") or "",
    frame = noctalia.state.get("last_frame") or "",
    error = noctalia.state.get("last_error") or "",
    at = tonumber(noctalia.state.get("last_at")) or 0,
    running = M.busy(),
  }
end

-- Notify the caller (or the user) that a request could not start. The watcher
-- passes announce=false, so the reason is always logged as well: otherwise
-- "missing binary" or a folder wallpaper disappears without a trace.
local function explain(reason, announce)
  if reason ~= "busy" then
    noctalia.log("matugen: skipped (" .. tostring(reason) .. ")")
  end
  if not announce then return end
  local title = noctalia.tr("toast.title")
  if reason == "busy" then
    noctalia.notify(title, noctalia.tr("toast.busy"))
  elseif reason == "no_wallpaper" then
    noctalia.notify(title, noctalia.tr("toast.no_wallpaper"))
  elseif reason == "missing_file" then
    noctalia.notify(title, noctalia.tr("toast.missing_file"))
  elseif reason == "directory" then
    noctalia.notify(title, noctalia.tr("toast.directory"))
  elseif reason == "video" then
    noctalia.notify(title, noctalia.tr("toast.video"))
  elseif reason == "no_ffmpeg" then
    noctalia.notifyError(title, noctalia.tr("toast.no_ffmpeg"))
  elseif reason == "missing_binary" then
    noctalia.notifyError(title, noctalia.tr("toast.missing_binary"))
  elseif reason == "spawn_failed" then
    noctalia.notifyError(title, noctalia.tr("toast.spawn_failed"))
  end
end

local function drain()
  if queued_path == nil then return end
  local path, opts = queued_path, queued_opts
  queued_path, queued_opts = nil, nil
  M.run(path, opts)
end

local function finishRun(phase, source, err, frame)
  running = false
  publish(phase, source, err, frame)
  unlock()
end

-- User callbacks must not be able to strand the queue: a throw in onDone would
-- otherwise skip drain() and leave a queued request pending forever.
local function notifyDone(opts, ok, err)
  if opts.onDone == nil then return end
  local called, message = pcall(opts.onDone, ok, err)
  if not called then
    noctalia.log("matugen: onDone failed (" .. tostring(message) .. ")")
  end
end

--- Hand the sampled frame back to Noctalia as the output's wallpaper, which is
--- what the old mpv hook did: it lets the shell's own palette (theme source =
--- wallpaper) follow the video too. Opt-in, and only when the frame is not
--- already the wallpaper.
local function handoffFrame(frame, source, assigned)
  if noctalia.getConfig("shell_wallpaper") ~= true then return end

  local targets = {}
  local outputs = noctalia.outputs()
  if outputs ~= nil then
    for _, output in ipairs(outputs) do
      if M.sourceFor(output.name, assigned) == source then
        targets[#targets + 1] = output.name
      end
    end
  end
  -- An assignment can be the "*" wildcard, so every output showing this source
  -- gets the frame; only fall back to the focused output when nothing matched.
  if #targets == 0 then
    local focused = noctalia.focusedOutputName()
    if focused ~= nil then targets[1] = focused end
  end

  for _, target in ipairs(targets) do
    if noctalia.wallpaperPath(target) ~= frame then
      noctalia.setWallpaper(target, frame)
      noctalia.log("matugen: handed the sampled frame to Noctalia on " .. target)
    end
  end
end

--- Run matugen on a ready image. Refreshes the lock so the matugen phase gets
--- a full TTL instead of whatever is left over from frame extraction.
local function launch(image, source, opts)
  lock()
  publish("running", source, nil, image)

  local started = noctalia.runAsync(M.args(image), function(result)
    local is_ok = result ~= nil and result.exitCode == 0
    local err = nil

    if is_ok then
      finishRun("ok", source, nil, image)
      if image ~= source then
        noctalia.log("matugen: palette regenerated from a frame of " .. source)
      else
        noctalia.log("matugen: palette regenerated from " .. image)
      end
    else
      local raw = ""
      if result ~= nil then
        raw = U.trim(result.stderr)
        if raw == "" then raw = U.trim(result.stdout) end
        if result.timedOut then raw = "timed out: " .. raw end
        raw = "exit " .. tostring(result.exitCode) .. ": " .. raw
      else
        raw = "no result"
      end
      err = raw
      if #err > 400 then err = string.sub(err, 1, 400) .. "..." end
      finishRun("error", source, err, image)
      noctalia.log("matugen: failed (" .. err .. ")")
      if cfg("notify_errors") ~= false then
        noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("toast.failed", { error = err }))
      end
    end

    notifyDone(opts, is_ok, err)
    drain()
  end)

  if not started then
    finishRun("error", source, "could not start matugen", image)
    noctalia.log("matugen: could not start " .. tostring(M.binary()))
    explain("spawn_failed", opts.announce == true)
    drain()
    return false, "spawn_failed"
  end

  return true, "started"
end

--- Run a regeneration for `source`, which may be an image or a video.
--- opts.announce: show a notification when the request cannot even start
--- opts.onDone(ok, err): called once the palette is done (or failed)
--- Returns ok, reason — "started", "extracting", "queued" or why it did not run.
function M.run(source, opts)
  opts = opts or {}
  local announce = opts.announce == true

  if source == nil or source == "" then
    explain("no_wallpaper", announce)
    return false, "no_wallpaper"
  end

  if running then
    -- Coalesce: whatever was asked for while the process was busy is applied
    -- right after it exits.
    queued_path = source
    queued_opts = opts
    return true, "queued"
  end

  if M.busy() then
    explain("busy", announce)
    return false, "busy"
  end

  local info = noctalia.fileInfo(source)
  if info == nil then
    explain("missing_file", announce)
    return false, "missing_file"
  end
  if info.isDir then
    -- The wallpaper source can be a folder when Noctalia cycles wallpapers;
    -- matugen has nothing to read there.
    explain("directory", announce)
    return false, "directory"
  end

  -- Video wallpaper: sample a still frame first, then colour from it.
  if video.isVideo(source) then
    if not video.enabled() then
      explain("video", announce)
      return false, "video"
    end
    if not video.available() then
      explain("no_ffmpeg", announce)
      return false, "no_ffmpeg"
    end
    local bin = M.binary()
    if not M.binaryAvailable(bin) then
      -- Check before spending time on a frame that could never be coloured.
      explain("missing_binary", announce)
      return false, "missing_binary"
    end

    running = true
    lock()
    publish("extracting", source, nil)

    local cached = video.ensureFrame(source, function(frame, err)
      if frame == nil then
        local reason = tostring(err or "frame extraction failed")
        finishRun("error", source, reason)
        noctalia.log("matugen: frame extraction failed (" .. reason .. ")")
        if cfg("notify_errors") ~= false then
          noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("toast.frame_failed", { error = reason }))
        end
        notifyDone(opts, false, reason)
        drain()
        return
      end
      handoffFrame(frame, source, video.assignments())
      launch(frame, source, opts)
    end)

    -- nil: ensureFrame failed before starting (its callback already reported
    -- it); false: ffmpeg is running; true: cached frame, launch() already ran.
    if cached == nil then return false, "frame_failed" end
    return true, cached and "started" or "extracting"
  end

  local bin = M.binary()
  if not M.binaryAvailable(bin) then
    explain("missing_binary", announce)
    return false, "missing_binary"
  end

  running = true
  lock()
  return launch(source, source, opts)
end

return M
