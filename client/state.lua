--- The store of live toasts: the schema, the ownership keys and the two queue ceilings.

OpxNotify = OpxNotify or {}

--- Mirrors `version` in open77.lua, which no Lua code can read. A release moves both lines.
OpxNotify.VERSION = "0.2.0"

local Config = OPX_NOTIFY_CONFIG

local State = {}
OpxNotify.state = State

-- Byte limits, as the platform states them.
local MAX_TITLE = 96
local MAX_MESSAGE = 384
local MAX_ICON = 16

--- Bounds on the two names: a notification id, and a resource name, which is what an owner
--- is. Read by the export surface and by the inbound handlers as well as here.
State.MAX_ID = 96
State.MAX_OWNER = 64

--- `0` is persistent; a timed toast is 750..120000 ms.
local MIN_TIMED_MS = 750
local MAX_TIMED_MS = 120000

--- What an unnamed toast's id is built from. A caller may spell an id of this shape, so
--- `State.autoId` steps past one that owner already holds.
local AUTO_ID_PREFIX = "notification_"

--- Bounds on a caller's opaque `data`, which rides in the removal event.
local MAX_DATA_NODES = 64
local MAX_DATA_DEPTH = 4

--- The most held at once, and the most one position holds; a ninth evicts that position's
--- oldest. Both are the documented numbers.
State.MAX_NOTIFICATIONS = 32
State.MAX_PER_POSITION = 8

--- Accent per kind. Duplicated in web/notify.css; change both together.
State.KINDS = {
  info = "#22D8E2",
  success = "#4FE3A9",
  warning = "#F5C95C",
  error = "#FF5964",
}

--- The platform's seven positions, and only those.
State.POSITIONS = {
  top_left = true,
  top_center = true,
  top_right = true,
  middle_left = true,
  bottom_left = true,
  bottom_center = true,
  bottom_right = true,
}

--- handle -> entry
State.entries = {}

--- owner-and-id -> handle. See `State.key` for why the separator is not a colon.
State.identities = {}

--- owner -> the generation we last saw it at
State.generations = {}

--- owner -> false once it has called setEnabled(false). Absent means enabled.
State.enabled = {}

--- Handles are client-local, monotonic and never reused within a session.
State.nextHandle = 1

--- The earliest deadline held, `nil` when nothing timed is. Only `State.put` lowers it and
--- only the tick recomputes it: a removal leaves it early, which costs one walk and nothing.
State.nextExpiryMs = nil

--- A finite number: a number, not NaN, neither infinity.
---@param value any
---@return boolean
local function finite(value)
  -- `value == value` is the NaN check: NaN is the one value unequal to itself
  return type(value) == "number" and value == value
    and value > -math.huge and value < math.huge
end

---@param value any
---@param maximum integer
---@return boolean
function State.validName(value, maximum)
  return type(value) == "string" and #value > 0 and #value <= maximum
    and value:match("^[%w_:%-%.]+$") ~= nil
end

--- Display copy: bounded, and refused rather than cleaned when it carries a control character.
---@param value any
---@param maximum integer
---@param allowEmpty boolean
---@return boolean
local function validText(value, maximum, allowEmpty)
  return type(value) == "string" and #value <= maximum
    and (allowEmpty or #value > 0) and value:find("[%c]") == nil
end

--- Normalise a colour to `#RRGGBB`, upper-cased. Three- and eight-digit forms are refused.
---@param value any
---@param fallback string|nil when nil, an absent value answers nil rather than a colour
---@return string|nil
local function normalizeColor(value, fallback)
  if value == nil then
    if fallback == nil then return nil end
    value = fallback
  end
  if type(value) ~= "string" then return nil end
  if value:match("^#%x%x%x%x%x%x$") == nil then return nil end
  return value:upper()
end

--- A shallow copy.
---@param source table|nil
---@return table
function State.copy(source)
  local result = {}
  for key, value in pairs(source or {}) do result[key] = value end
  return result
end

--- Count a caller's opaque table, refusing rather than truncating it.
---@param value any
---@param depth integer
---@param budget table
---@return boolean
local function fitsInPayload(value, depth, budget)
  budget.nodes = budget.nodes + 1
  if budget.nodes > MAX_DATA_NODES then return false end
  if type(value) ~= "table" then return true end
  if depth > MAX_DATA_DEPTH then return false end
  for key, nested in pairs(value) do
    if not fitsInPayload(key, depth + 1, budget) then return false end
    if not fitsInPayload(nested, depth + 1, budget) then return false end
  end
  return true
end

--- The identity key for one owner's id. The separator is `\1`, not `:`, because both halves
--- may contain a colon.
---@param owner string
---@param id string
---@return string
function State.key(owner, id)
  return owner .. "\1" .. id
end

--- The id a definition that names none is given: `notification_<handle>`, or the next free
--- number when this owner already holds that id.
---@param owner string
---@param handle integer|nil
---@return string
function State.autoId(owner, handle)
  local number = handle or State.nextHandle
  while true do
    local id = AUTO_ID_PREFIX .. tostring(number)
    local taken = State.identities[State.key(owner, id)]
    if taken == nil or taken == handle then return id end
    number = number + 1
  end
end

--- Validate a definition and turn it into a stored entry. Whole or not at all: a refusal
--- leaves nothing behind.
---@param owner string
---@param definition any
---@param handle integer|nil the handle to reuse when re-normalising, nil for a new entry
---@param atMs integer the monotonic clock the deadline is computed against
---@return table|nil entry
---@return string|nil reason
function State.normalize(owner, definition, handle, atMs)
  if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end

  -- `type` and `kind` are aliases; `type` wins.
  local kind = definition.type
  if kind == nil then kind = definition.kind end
  if kind == nil then kind = "info" end
  if type(kind) ~= "string" then return nil, "invalid_type" end
  kind = kind:lower()
  if State.KINDS[kind] == nil then return nil, "invalid_type" end

  local id = definition.id
  if id == nil then id = State.autoId(owner, handle) end
  if not State.validName(id, State.MAX_ID) then return nil, "invalid_notification_id" end

  local title = definition.title
  if title == nil then title = "" end
  if not validText(title, MAX_TITLE, true) then return nil, "invalid_title" end

  -- `message` and `text` are aliases; the body is required.
  local message = definition.message
  if message == nil then message = definition.text end
  if not validText(message, MAX_MESSAGE, false) then return nil, "invalid_message" end

  local icon = definition.icon
  if icon ~= nil and not validText(icon, MAX_ICON, true) then return nil, "invalid_icon" end

  local position = definition.position
  if position == nil then position = Config.POSITION end
  if State.POSITIONS[position] == nil then return nil, "invalid_position" end

  -- `durationMs` and `duration` are aliases.
  local durationMs = definition.durationMs
  if durationMs == nil then durationMs = definition.duration end
  if durationMs == nil then durationMs = Config.DURATION_MS end
  if not finite(durationMs) or durationMs % 1 ~= 0 or durationMs < 0 then
    return nil, "invalid_duration"
  end
  if durationMs > MAX_TIMED_MS then return nil, "invalid_duration" end
  if durationMs > 0 and durationMs < MIN_TIMED_MS then return nil, "invalid_duration" end

  local progress = definition.progress
  if progress == nil then progress = Config.PROGRESS end
  if type(progress) ~= "boolean" then return nil, "invalid_progress" end

  -- `nil` falls back to the kind's accent; anything present must be a real `#RRGGBB`.
  local color = normalizeColor(definition.color, State.KINDS[kind])
  if color == nil then return nil, "invalid_color" end

  -- A non-table `data` is ignored rather than refused; a table is bounded.
  local data = definition.data
  if type(data) ~= "table" then
    data = {}
  elseif not fitsInPayload(data, 1, { nodes = 0 }) then
    return nil, "data_too_large"
  end

  return {
    handle = handle,
    owner = owner,
    id = id,
    kind = kind,
    title = title,
    message = message,
    icon = icon or "",
    position = position,
    durationMs = durationMs,
    -- a persistent toast has no lifetime to draw, whatever the caller asked for
    progress = progress and durationMs > 0,
    -- what the caller asked for, so a later patch can re-derive rather than inherit
    progressWanted = progress,
    color = color,
    -- nil unless the caller pinned one, so a change of kind re-derives the accent
    colorWanted = normalizeColor(definition.color, nil),
    createdAtMs = atMs,
    -- Lua's own deadline; it never crosses to the page, which is sent `durationMs` instead
    expiresAtMs = durationMs > 0 and (atMs + durationMs) or nil,
    data = data,
  }
end

--- One stored entry expressed as a definition again, which is what a patch is merged over.
--- Only the primary spelling of each aliased field appears.
---@param entry table
---@return table
function State.definitionOf(entry)
  return {
    id = entry.id,
    type = entry.kind,
    title = entry.title,
    message = entry.message,
    icon = entry.icon,
    position = entry.position,
    durationMs = entry.durationMs,
    progress = entry.progressWanted,
    color = entry.colorWanted,
    data = entry.data,
  }
end

--- Collapse the documented aliases onto one spelling each, so a patch spelling an alias
--- cannot sit beside the stored primary spelling and lose to it on merge.
---@param definition table
---@return table
function State.canonical(definition)
  local out = State.copy(definition)
  if out.type == nil and out.kind ~= nil then out.type = out.kind end
  out.kind = nil
  if out.message == nil and out.text ~= nil then out.message = out.text end
  out.text = nil
  if out.durationMs == nil and out.duration ~= nil then out.durationMs = out.duration end
  out.duration = nil
  return out
end

--- What crosses to the page, and what `list` answers. `owner` and `data` stay in Lua.
---@param entry table
---@return table
function State.payload(entry)
  return {
    handle = entry.handle,
    id = entry.id,
    type = entry.kind,
    title = entry.title,
    message = entry.message,
    icon = entry.icon,
    position = entry.position,
    durationMs = entry.durationMs,
    progress = entry.progress,
    color = entry.color,
  }
end

---@return integer
function State.count()
  local total = 0
  for _ in pairs(State.entries) do total = total + 1 end
  return total
end

--- The oldest entry in one position, and how many that position holds.
---@param position string
---@return table|nil oldest
---@return integer held
function State.oldestAt(position)
  local oldest, held = nil, 0
  for _, entry in pairs(State.entries) do
    if entry.position == position then
      held = held + 1
      if oldest == nil or entry.createdAtMs < oldest.createdAtMs
        or (entry.createdAtMs == oldest.createdAtMs and entry.handle < oldest.handle) then
        -- the handle breaks a tie: two toasts raised in one frame share a millisecond
        oldest = entry
      end
    end
  end
  return oldest, held
end

---@param handle any
---@return table|nil
function State.get(handle)
  handle = tonumber(handle)
  if handle == nil then return nil end
  return State.entries[handle]
end

--- Store an entry, minting a handle when it has none.
---@param entry table
---@return table entry
function State.put(entry)
  if entry.handle == nil then
    entry.handle = State.nextHandle
    State.nextHandle = State.nextHandle + 1
  end
  State.entries[entry.handle] = entry
  State.identities[State.key(entry.owner, entry.id)] = entry.handle
  if entry.expiresAtMs ~= nil
    and (State.nextExpiryMs == nil or entry.expiresAtMs < State.nextExpiryMs) then
    State.nextExpiryMs = entry.expiresAtMs
  end
  return entry
end

---@param handle integer
---@return table|nil removed
function State.remove(handle)
  local entry = State.entries[handle]
  if entry == nil then return nil end
  State.entries[handle] = nil
  State.identities[State.key(entry.owner, entry.id)] = nil
  return entry
end

--- Every handle one owner holds, as a list, so a sweep does not mutate the table it walks.
---@param owner string
---@return integer[]
function State.handlesOf(owner)
  local handles, count = {}, 0
  for handle, entry in pairs(State.entries) do
    if entry.owner == owner then
      count = count + 1
      handles[count] = handle
    end
  end
  return handles
end

--- Whether this owner has its notifications on. One that never called `setEnabled` is on.
---@param owner string
---@return boolean
function State.isEnabled(owner)
  return State.enabled[owner] ~= false
end

---@param owner string
---@param value any anything but `false` enables
---@return boolean enabled the state it now holds
function State.setEnabled(owner, value)
  State.enabled[owner] = value ~= false
  return State.enabled[owner]
end

--- The owner name for a server-sent toast. `@` is outside the class a client owner is
--- validated against, so a client resource can never address one.
---@param value any the resource name carried in the envelope
---@return string|nil
function State.serverOwner(value)
  if not State.validName(value, State.MAX_OWNER) then return nil end
  return "@server:" .. value
end
