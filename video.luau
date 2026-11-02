--!nonstrict
-- Video wallpaper support.
--
-- Matugen needs a still image, so a video wallpaper is sampled with ffmpeg into
-- a cached JPEG and Matugen runs on that frame. The same trick the `mpv/`
-- scripts use (`ffmpeg -ss 1 -vframes 1`), with two differences:
--   * the cache lives in the plugin data dir and is keyed by path+mtime+size,
--     so editing or replacing a video re-samples it instead of serving a stale
--     frame;
--   * the source video is also discovered from the mpvpaper plugin's
--     assignments, since while a video owns an output Noctalia's own wallpaper
--     path still points at the previous static image.

local U = require("./util.luau")

local M = {}

local VIDEO_EXT = {
  mp4 = true, webm = true, mkv = true, m4v = true,
  mov = true, avi = true, ogv = true, wmv = true, gif = true,
}

local CACHE_SUBDIR = "frames"
local MAX_CACHE_FILES = 24   -- prune above this many cached frames
local KEEP_CACHE_FILES = 12  -- ... down to this many

local assignments = nil
local assignments_stamp = nil

function M.isVideo(path)
  local ext = string.match(path or "", "%.([%w]+)$")
  if ext == nil then return false end
  return VIDEO_EXT[string.lower(ext)] == true
end

--- Whether video wallpapers are sampled at all (`video_mode != "off"`).
function M.enabled()
  return tostring(U.cfg("video_mode", "auto")) ~= "off"
end

function M.ffmpeg()
  return U.expand(tostring(U.cfg("ffmpeg_path", "ffmpeg")))
end

function M.available()
  local bin = M.ffmpeg()
  if bin == "" then return false end
  if string.find(bin, "/", 1, true) ~= nil then
    return noctalia.fileExists(bin)
  end
  return noctalia.commandExists(bin)
end

local function assignmentsPath()
  local custom = U.expand(tostring(U.cfg("assignments_file", "")))
  if custom ~= "" then return custom end
  -- Same location the mpvpaper plugin writes to (XDG state dir by default).
  local state = noctalia.getenv("XDG_STATE_HOME")
  if state == nil or state == "" then
    local home = noctalia.getenv("HOME")
    if home == nil or home == "" then return nil end
    state = home .. "/.local/state"
  end
  return state .. "/noctalia/mpvpaper/assignments.json"
end

--- connector -> video path, as assigned by the mpvpaper plugin. Re-read only
--- when the file's mtime moves, so polling stays a single stat per tick.
function M.assignments()
  local path = assignmentsPath()
  if path == nil then return {} end

  local info = noctalia.fileInfo(path)
  if info == nil or info.isDir then
    assignments, assignments_stamp = {}, nil
    return assignments
  end

  -- Noctalia may expose mtime as a float whose last digits are unstable
  -- between calls; whole seconds plus size is the stable key. Size still
  -- catches a rewrite within the same second.
  local stamp = tostring(math.floor(tonumber(info.mtime) or 0)) .. ":" .. tostring(info.size)
  if assignments ~= nil and assignments_stamp == stamp then
    return assignments
  end

  local raw = noctalia.readFile(path)
  local decoded = nil
  if raw ~= nil then
    decoded = noctalia.json.decode(raw)
  end

  if type(decoded) ~= "table" then
    -- The mpvpaper service rewrites this file in place, so a read can land on
    -- a partial write. Keep the last good map and retry next tick instead of
    -- caching the failure until the next change.
    if assignments == nil then assignments = {} end
    return assignments
  end

  -- Current mpvpaper writes { assignments, lastAssignments, launchedAsSystemd };
  -- older versions wrote the connector map directly. Read the active map and
  -- keep the "*" wildcard exactly as written.
  local root = decoded.assignments
  if type(root) ~= "table" then root = decoded end

  local map = {}
  local count = 0
  for key, value in pairs(root) do
    if type(value) == "string" and value ~= "" then
      map[tostring(key)] = value
      count = count + 1
    end
  end

  assignments = map
  assignments_stamp = stamp
  noctalia.log("matugen: read " .. tostring(count) .. " mpvpaper assignment(s)")
  return assignments
end

local cache_dir_cached = nil

local function cacheDir()
  if cache_dir_cached ~= nil then return cache_dir_cached end
  local base = noctalia.pluginDataDir()
  if base == nil then return nil end
  cache_dir_cached = base .. "/" .. CACHE_SUBDIR
  noctalia.mkdirAll(cache_dir_cached)
  return cache_dir_cached
end

--- True when `path` is a frame this plugin sampled (and not a real wallpaper).
--- Used to keep the polling loop and the cache clean-up from feeding on our own
--- output once a frame has been handed to the shell as the wallpaper.
function M.isFrame(path)
  if path == nil or path == "" then return false end
  local dir = cacheDir()
  if dir == nil then return false end
  return string.sub(path, 1, #dir + 1) == dir .. "/"
end

local function cacheKey(source, info)
  local offset = tonumber(U.cfg("frame_offset", 1.0)) or 0
  local width = math.floor(tonumber(U.cfg("frame_width", 1280)) or 0)
  local stamp = "?"
  if info ~= nil then
    -- Normalize mtime: Noctalia can return the same timestamp with different
    -- trailing digits on consecutive calls, which would otherwise rotate the
    -- frame cache key and re-run ffmpeg for no reason.
    stamp = tostring(math.floor(tonumber(info.mtime) or 0)) .. "x" .. tostring(info.size)
  end
  return U.hash(source .. "|" .. stamp .. "|" .. tostring(offset) .. "|" .. tostring(width))
end

local function prune(dir)
  local names = noctalia.listDir(dir)
  if names == nil or #names <= MAX_CACHE_FILES then return end

  local entries = {}
  for _, name in ipairs(names) do
    if string.match(name, "%.jpg$") ~= nil then
      local path = dir .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info ~= nil then
        entries[#entries + 1] = { path = path, mtime = info.mtime }
      end
    end
  end
  if #entries <= KEEP_CACHE_FILES then return end

  -- Never drop a frame that some output is currently using as its wallpaper
  -- (shell_wallpaper hands frames over exactly that way).
  local active = {}
  local outputs = noctalia.outputs()
  if outputs ~= nil then
    for _, output in ipairs(outputs) do
      local wp = noctalia.wallpaperPath(output.name)
      if wp ~= nil and wp ~= "" then active[wp] = true end
    end
  end

  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  for i = KEEP_CACHE_FILES + 1, #entries do
    if not active[entries[i].path] then
      noctalia.removeFile(entries[i].path)
    end
  end
end

--- Extract one frame at `offset` seconds into `target`, falling back to the
--- first frame when the video is shorter than the offset.
local function extract(bin, source, target, offset, width, onDone)
  local argv = { bin, "-nostdin", "-y", "-loglevel", "error" }
  if offset > 0 then
    -- -ss before -i is the fast seek; frame-accurate decoding is pointless for
    -- a colour sample.
    argv[#argv + 1] = "-ss"
    argv[#argv + 1] = tostring(offset)
  end
  argv[#argv + 1] = "-i"
  argv[#argv + 1] = source
  argv[#argv + 1] = "-frames:v"
  argv[#argv + 1] = "1"
  argv[#argv + 1] = "-an"
  argv[#argv + 1] = "-sn"
  argv[#argv + 1] = "-dn"
  if width > 0 then
    argv[#argv + 1] = "-vf"
    argv[#argv + 1] = string.format("scale=%d:-2:flags=bicubic", width)
  end
  argv[#argv + 1] = "-q:v"
  argv[#argv + 1] = "2"
  argv[#argv + 1] = target

  local started = noctalia.runAsync(argv, function(result)
    local ok = result ~= nil and result.exitCode == 0 and noctalia.fileInfo(target) ~= nil
    onDone(ok, result)
  end)

  if not started then onDone(false, nil) end
end

--- Ensure a cached still frame for `video`, then call
--- `cb(frame_path)` or `cb(nil, error)`.
--- Returns true when a cached frame was reused (cb ran synchronously), false
--- when extraction was started, and nil when it failed before starting.
function M.ensureFrame(video, cb)
  if video == nil or video == "" then
    cb(nil, "no video path")
    return nil
  end

  local dir = cacheDir()
  if dir == nil then
    cb(nil, "no plugin data directory")
    return nil
  end

  local info = noctalia.fileInfo(video)
  if info == nil or info.isDir then
    cb(nil, "video not found: " .. video)
    return nil
  end

  local target = dir .. "/" .. cacheKey(video, info) .. ".jpg"
  local cached = noctalia.fileInfo(target)
  if cached ~= nil and cached.size > 0 then
    noctalia.log("matugen: reusing cached frame from " .. video)
    cb(target)
    return true
  end

  local bin = M.ffmpeg()
  if not M.available() then
    cb(nil, "ffmpeg not found: " .. bin)
    return nil
  end

  local offset = tonumber(U.cfg("frame_offset", 1.0)) or 0
  local width = math.floor(tonumber(U.cfg("frame_width", 1280)) or 0)
  local tmp = target .. ".part.jpg"

  local function attempt(seek, retried)
    extract(bin, video, tmp, seek, width, function(ok, result)
      if not ok then
        noctalia.removeFile(tmp)
        if seek > 0 and not retried then
          -- Video shorter than the configured offset: take its first frame.
          attempt(0, true)
          return
        end
        local err = "ffmpeg failed"
        if result ~= nil then
          local detail = U.trim(result.stderr)
          if detail ~= "" then err = err .. ": " .. detail end
        end
        if #err > 300 then err = string.sub(err, 1, 300) .. "..." end
        cb(nil, err)
        return
      end

      noctalia.renameFile(tmp, target)
      if noctalia.fileInfo(target) == nil then
        noctalia.removeFile(tmp)
        cb(nil, "could not store frame in " .. dir)
        return
      end
      prune(dir)
      noctalia.log("matugen: sampled frame from " .. video)
      cb(target)
    end)
  end

  noctalia.log("matugen: sampling a frame from " .. video)
  attempt(offset, false)
  return false
end

return M
