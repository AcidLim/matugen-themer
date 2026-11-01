--!nonstrict
-- Small shared helpers: setting reads, `~` expansion, and a 32-bit hash used
-- for naming cached video frames.

local M = {}

--- Read a plugin setting, treating nil/blank strings as "not set".
function M.cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then return fallback end
  if type(value) == "string" and noctalia.string.trim(value) == "" then return fallback end
  return value
end

function M.trim(text)
  if text == nil then return "" end
  return noctalia.string.trim(tostring(text))
end

--- Expand a leading `~` only. A bare command name ("matugen", "ffmpeg") must
--- stay bare so it can be looked up on $PATH instead of being turned into a
--- relative path.
function M.expand(path)
  if path == nil or path == "" then return "" end
  local text = tostring(path)
  if string.sub(text, 1, 1) ~= "~" then return text end
  return noctalia.expandPath(text)
end

-- 32-bit multiply without 64-bit integers: split into 16-bit halves so every
-- intermediate value stays far below 2^53 and doubles stay exact.
local function mul32(a, b)
  local a_lo = a % 65536
  local a_hi = math.floor(a / 65536)
  local b_lo = b % 65536
  local b_hi = math.floor(b / 65536)
  local mid = (a_hi * b_lo + a_lo * b_hi) % 65536
  return (mid * 65536 + a_lo * b_lo) % 4294967296
end

--- FNV-1a, rendered as 8 hex chars. Good enough to name cache files: a
--- collision only means one video reuses another's cached frame.
function M.hash(text)
  local h = 2166136261
  for i = 1, #text do
    h = bit32.bxor(h, string.byte(text, i))
    h = mul32(h, 16777619)
  end
  return string.format("%08x", h)
end

return M
