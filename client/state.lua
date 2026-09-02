--- The store of live toasts: the schema, the ownership keys and the two queue ceilings.
---
--- Every limit in this file is the platform's, taken from `notifications.md`'s definition
--- reference and cross-checked against the shipped `open77_notifications/client/main.lua`:
--- a title of 96 UTF-8 bytes, a body of 384, an icon of 16, an id of 96 matching
--- `^[%w_:%-%.]+$`, a duration of `0` or 750..120000, at most 32 toasts held and at most
--- eight per position. They are not ours to loosen: third-party code written against the
--- documented surface has to behave here exactly as it does there.

OpxNotify = OpxNotify or {}

--- Mirrors `version` in open77.lua, which no Lua code can read. Nothing checks that the two
--- agree, so a release moves both lines or the copy a caller reads is a lie.
OpxNotify.VERSION = "0.1.0"

local Config = OPX_NOTIFY_CONFIG

local State = {}
OpxNotify.state = State

--- `#` counts bytes in Lua, which is what the platform's own limits are stated in.
local MAX_TITLE = 96
local MAX_MESSAGE = 384
local MAX_ICON = 16
local MAX_ID = 96

--- Resource names, which is what an owner is. The host answers `GetInvokingResource` with a
--- manifest name and those are short; 64 is the bound every OPX resource applies to one.
local MAX_OWNER = 64

--- `0` is persistent. A timed toast is 750..120000 ms -- below 750 the entrance animation
--- has not finished before the exit one starts, above two minutes it is a panel, not a toast.
local MIN_TIMED_MS = 750
local MAX_TIMED_MS = 120000

--- `data` rides in every local event raised on removal: the host drops a payload past 1024
--- nodes in silence, so a caller's opaque table is counted rather than truncated.
local MAX_DATA_NODES = 64
local MAX_DATA_DEPTH = 4

--- The most this resource holds at once, and the most one position holds. Adding a ninth
--- toast to a position evicts that position's oldest. Guard rails against a caller that
--- leaks, not numbers an operator would tune -- and they are the documented ones, so raising
--- them here would make this resource behave differently from the package it stands in for.
State.MAX_NOTIFICATIONS = 32
State.MAX_PER_POSITION = 8

--- Accent per kind. These are the OPEN//77 signal tokens and they are kept in step with
--- `web/open77-ui.css` (--op77-accent, --op77-ok, --op77-warn, --op77-signal) and with the
--- same four literals in the official package's client/main.lua. Change them here and in
--- web/notify.css together, or a toast's Lua colour and its CSS class disagree.
State.KINDS = {
  info = "#22D8E2",
  success = "#4FE3A9",
  warning = "#F5C95C",
  error = "#FF5964",
}

--- The platform's seven positions, and only those. There is no `middle_right` and no
--- `middle_center`: the set is asymmetric in the published schema, and inventing the missing
--- two would give a caller a position the official package refuses.
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

--- A finite number: a number, not NaN, and neither infinity. One predicate, spelled the same
--- way in every resource of this framework.
---@param value any
---@return boolean
local function finite(value)
  -- `value == value` is the NaN check, not a typo: NaN is the one value unequal to itself
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

--- Display copy: bounded, and refused rather than cleaned when it carries a control
--- character. The page inserts every string with `textContent`, so nothing here can become
--- markup; a control character would still ruin the line it lands in.
---@param value any
---@param maximum integer
---@param allowEmpty boolean
---@return boolean
local function validText(value, maximum, allowEmpty)
  return type(value) == "string" and #value <= maximum
    and (allowEmpty or #value > 0) and value:find("[%c]") == nil
end

--- `#RRGGBB`, upper-cased. Three-digit and eight-digit forms are refused: the page writes the
--- value straight into a custom property and a caller that meant `#abc` gets to hear so.
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

--- A shallow copy. There is no `setmetatable` in this sandbox, so this is a plain loop and
--- never a proxy.
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

--- The identity key for one owner's id.
---
--- `\1`, not `:`, because both halves may contain a colon: an id may (`^[%w_:%-%.]+$` allows
--- it) and a server owner is stored as `@server:<resource>`. With a colon separator the pair
--- ("a", "b:c") and the pair ("a:b", "c") produce the same key, and one resource's update
--- would land on another's toast. `\1` cannot occur in either half -- `%w_:%-%.` excludes it,
--- and so does every resource name.
---@param owner string
---@param id string
---@return string
function State.key(owner, id)
  return owner .. "\1" .. id
end

--- Validate a definition and turn it into a stored entry. Whole or not at all: a refusal
--- leaves nothing behind, so a caller never has to undo a half-applied definition.
---
--- `handle` is the handle to reuse when re-normalising an entry that already exists, and nil
--- for a new one. `atMs` is the monotonic clock the deadline is computed against.
---@param owner string
---@param definition any
---@param handle integer|nil
---@param atMs integer
---@return table|nil entry
---@return string|nil reason
function State.normalize(owner, definition, handle, atMs)
  if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end

  -- `type` and `kind` are aliases in the documented schema. Both are read; neither is
  -- invented. `type` first, because that is the name the documentation's examples use.
  -- `State.canonical` has already collapsed the pair on every merge path, so this branch
  -- only ever decides for a definition that arrived straight from a caller.
  local kind = definition.type
  if kind == nil then kind = definition.kind end
  if kind == nil then kind = "info" end
  if type(kind) ~= "string" then return nil, "invalid_type" end
  kind = kind:lower()
  if State.KINDS[kind] == nil then return nil, "invalid_type" end

  local id = definition.id
  if id == nil then id = "notification_" .. tostring(handle or State.nextHandle) end
  if not State.validName(id, MAX_ID) then return nil, "invalid_notification_id" end

  local title = definition.title
  if title == nil then title = "" end
  if not validText(title, MAX_TITLE, true) then return nil, "invalid_title" end

  -- `message` and `text` are aliases in the documented schema, and the body is required:
  -- a toast with a title and nothing under it is a label, not a notification.
  local message = definition.message
  if message == nil then message = definition.text end
  if not validText(message, MAX_MESSAGE, false) then return nil, "invalid_message" end

  local icon = definition.icon
  if icon ~= nil and not validText(icon, MAX_ICON, true) then return nil, "invalid_icon" end

  -- The one default that departs from the official package's, and the only one. See
  -- OPX_NOTIFY_CONFIG.POSITION for why.
  local position = definition.position
  if position == nil then position = Config.POSITION end
  if State.POSITIONS[position] == nil then return nil, "invalid_position" end

  -- `durationMs` and `duration` are aliases in the documented schema.
  local durationMs = definition.durationMs
  if durationMs == nil then durationMs = definition.duration end
  if durationMs == nil then durationMs = Config.DURATION_MS end
  if not finite(durationMs) or durationMs % 1 ~= 0 or durationMs < 0 then
    return nil, "invalid_duration"
  end
  if durationMs > MAX_TIMED_MS then return nil, "invalid_duration" end
  if durationMs > 0 and durationMs < MIN_TIMED_MS then return nil, "invalid_duration" end

  -- The official package writes `definition.progress ~= false`, which is a boolean by
  -- construction, and then checks that boolean is a boolean -- so its `invalid_progress`
  -- can never fire and `progress = "yes"` reads as true. Ours refuses anything that is
  -- neither nil nor a boolean. It is the one rule here that is stricter than the package
  -- it mirrors, and it is stricter in the direction of telling a caller about its bug.
  local progress = definition.progress
  if progress == nil then progress = Config.PROGRESS end
  if type(progress) ~= "boolean" then return nil, "invalid_progress" end

  -- `nil` falls back to the kind's accent; anything present must be a real `#RRGGBB`.
  local color = normalizeColor(definition.color, State.KINDS[kind])
  if color == nil then return nil, "invalid_color" end

  -- A non-table `data` is ignored rather than refused, which is what the official package
  -- does; a table is bounded, because it is echoed back in a local event.
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
    -- What the caller ASKED for, kept beside what was drawn. A toast made persistent and
    -- then given a duration again by a patch that says nothing about `progress` gets its bar
    -- back; storing only the reduced value would have lost the request on the way through.
    progressWanted = progress,
    color = color,
    -- nil unless the caller pinned one. `color` above is the resolved accent, which is the
    -- kind's default when nothing was pinned -- and carrying THAT back into a patch is what
    -- makes the official package's own documented example wrong: `update(handle, { type =
    -- "success" })` there re-normalises the stored cyan and the toast stays cyan. Keeping
    -- the request separate lets a change of kind re-derive the accent, while a caller that
    -- named a colour keeps the colour it named.
    colorWanted = normalizeColor(definition.color, nil),
    createdAtMs = atMs,
    -- absolute, not remaining: the page counts down from this on its own clock
    expiresAtMs = durationMs > 0 and (atMs + durationMs) or nil,
    data = data,
  }
end

--- One stored entry expressed as a definition again, which is what a patch is merged over.
---
--- Only the primary spelling of each aliased field appears, so a patch that names an alias
--- (`text`, `kind`, `duration`) overrides it -- see `State.canonical`, which is what puts the
--- patch into the same spelling first.
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

--- Collapse the documented aliases onto one spelling each.
---
--- Merging is why this exists. A stored entry becomes a definition spelling its body
--- `message`; a patch that spells it `text` would then leave BOTH keys in the merged table,
--- and `normalize` reads `message` first -- so the patch would be silently ignored. The same
--- trap is set by `kind` against `type` and by `duration` against `durationMs`. Collapsing
--- the patch before the merge is the only place this can be fixed once for all three.
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

--- What crosses to the page, and what `list` answers. `owner` and `data` stay in Lua: the
--- page has no use for either, and `data` is the caller's, not the renderer's.
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

--- The oldest entry in one position, and how many that position holds. One pass, because
--- both answers are wanted at the same moment and `pairs` over 32 entries twice is twice.
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
        -- the handle breaks a tie: two toasts raised in one frame share a millisecond, and
        -- `pairs` order would otherwise decide which of them is evicted
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

--- Every handle one owner holds, as a list, so a caller can be swept without mutating the
--- table `pairs` is walking.
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

--- Whether this owner has turned its own notifications off. Absent means on: an owner that
--- has never called `setEnabled` is enabled.
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

--- Owner names for server-sent toasts.
---
--- The prefix is the official package's, byte for byte, and it is what keeps a client
--- resource from forging one: `@` is outside `^[%w_:%-%.]+$`, so no value `GetInvokingResource`
--- can ever answer collides with a server owner, and no export argument names an owner at all.
---@param value any the resource name carried in the envelope
---@return string|nil
function State.serverOwner(value)
  if not State.validName(value, MAX_OWNER) then return nil end
  return "@server:" .. value
end
