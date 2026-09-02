--- The surface, the sweep, and the four `open77:notifications:*` net events the platform's
--- server runtime fires.

OpxNotify = OpxNotify or {}

local Config = OPX_NOTIFY_CONFIG
local State = OpxNotify.state

local RESOURCE = GetCurrentResourceName()

--- How often deadlines are checked. The page animates its own bar off the `durationMs` it
--- was sent, on its own clock, so the two never have to agree.
local TICK_MS = 100

--- How often every owner is re-checked against the host, as a backstop to
--- `onClientResourceStop`.
local OWNER_SWEEP_MS = 1000

--- The removal event. Local, never a wire name: raising a wire name would re-enter its own
--- RegisterNetEvent handler forever.
local REMOVED_EVENT = "opx77:notify:removed"

--- The WebUI IPC channels, private to this resource's own surface.
local PAGE_READY = "notify:ready"
local PAGE_DIAG = "notify:diag"

local page = nil
local pageReady = false

--- Whether `WebUI.create` has been attempted, which is not whether there is a page.
local surfaceAttempted = false

local Runtime = {}
OpxNotify.runtime = Runtime

--- The scheduler clock in milliseconds; `monotonic` answers SECONDS. A non-finite reading is
--- dropped rather than propagated: a NaN would expire nothing, an infinity everything.
---@return integer
local lastMs = 0
local function nowMs()
  local read, seconds = pcall(Open77.time.monotonic)
  if read and type(seconds) == "number" and seconds == seconds and
    seconds >= 0 and seconds < math.huge then
    lastMs = math.floor(seconds * 1000)
  end
  return lastMs
end

---@param action string one of "config", "add", "update", "remove"
---@param value table|nil
local function send(action, value)
  if page ~= nil and pageReady then page:send("notify:" .. action, value or {}) end
end

-- ---------------------------------------------------------------------------
-- Removal, and the event it raises
-- ---------------------------------------------------------------------------

--- Take one toast down and tell its owner why.
---@param handle integer
---@param reason string
---@param quiet boolean|nil suppress the removal event; only this resource's own stop does
---@return boolean
local function removeInternal(handle, reason, quiet)
  local entry = State.remove(handle)
  if entry == nil then return false end
  send("remove", { handle = handle, reason = reason })
  if quiet then return true end
  TriggerEvent(REMOVED_EVENT, {
    handle = handle,
    id = entry.id,
    owner = entry.owner,
    reason = reason,
    data = entry.data,
  })
  return true
end

---@param owner string
---@param reason string
---@param quiet boolean|nil
---@return integer removed
local function removeOwner(owner, reason, quiet)
  -- collected first: `removeInternal` mutates the table a `pairs` loop would be walking
  local handles = State.handlesOf(owner)
  local removed = 0
  for index = 1, #handles do
    if removeInternal(handles[index], reason, quiet) then removed = removed + 1 end
  end
  return removed
end

--- Make room in one position before a new toast joins it; the oldest goes.
---@param position string
local function evictPosition(position)
  local oldest, held = State.oldestAt(position)
  if held < State.MAX_PER_POSITION or oldest == nil then return end
  removeInternal(oldest.handle, "queue_limit")
end

-- ---------------------------------------------------------------------------
-- The operations, in terms of an owner that has already been established
-- ---------------------------------------------------------------------------

--- The shape every operation and every export answers.
---@param ok boolean
---@param values table|nil
---@return table
function Runtime.response(ok, values)
  values = values or {}
  values.ok = ok == true
  return values
end

local response = Runtime.response

--- Refuse when there is no page and never will be. A page that exists but has not reported
--- ready is not a refusal: entries are held and replayed on `notify:ready`.
---@return table|nil refusal
local function noSurface()
  if surfaceAttempted and page == nil then
    return response(false, { error = "no_surface" })
  end
  return nil
end

---@param owner string
---@param definition any
---@return table
function Runtime.show(owner, definition)
  local refused = noSurface()
  if refused then return refused end
  if not State.isEnabled(owner) then return response(false, { error = "owner_disabled" }) end

  local atMs = nowMs()
  local wantedId = type(definition) == "table" and definition.id or nil
  local existing = nil
  if type(wantedId) == "string" then existing = State.identities[State.key(owner, wantedId)] end

  if existing ~= nil then
    -- Replacing in place, not adding, so the ceilings do not apply.
    if definition.replace ~= true then
      return response(false, { error = "duplicate_notification_id" })
    end
    local current = State.entries[existing]
    -- merged in one spelling: `State.canonical` collapses the aliases first
    local merged = State.definitionOf(current)
    for key, value in pairs(State.canonical(definition)) do merged[key] = value end
    local replacement, reason = State.normalize(owner, merged, existing, atMs)
    if replacement == nil then return response(false, { error = reason }) end
    -- Landing in another position is a ninth toast there; the page evicts either way.
    if replacement.position ~= current.position then evictPosition(replacement.position) end
    State.put(replacement)
    send("update", State.payload(replacement))
    return response(true, { handle = existing, id = replacement.id, replaced = true })
  end

  if State.count() >= State.MAX_NOTIFICATIONS then
    return response(false, { error = "notification_limit" })
  end

  local entry, reason = State.normalize(owner, definition, nil, atMs)
  if entry == nil then return response(false, { error = reason }) end
  evictPosition(entry.position)
  State.put(entry)
  send("add", State.payload(entry))
  return response(true, { handle = entry.handle, id = entry.id })
end

---@param owner string
---@param handle any
---@param patch any
---@return table
function Runtime.update(owner, handle, patch)
  local refused = noSurface()
  if refused then return refused end

  local current = State.get(handle)
  if current == nil then return response(false, { error = "notification_not_found" }) end
  if current.owner ~= owner then return response(false, { error = "not_owner" }) end
  if type(patch) ~= "table" then return response(false, { error = "patch_must_be_a_table" }) end

  local merged = State.definitionOf(current)
  for key, value in pairs(State.canonical(patch)) do merged[key] = value end
  -- The id is the toast's identity and a patch does not get to move it: `identities` is
  -- keyed on it.
  merged.id = current.id

  -- A patch that says nothing about the deadline keeps the one it had.
  local touchesDuration = patch.durationMs ~= nil or patch.duration ~= nil

  local replacement, reason = State.normalize(owner, merged, current.handle, nowMs())
  if replacement == nil then return response(false, { error = reason }) end
  if not touchesDuration then
    replacement.createdAtMs = current.createdAtMs
    replacement.expiresAtMs = current.expiresAtMs
  end
  -- Landing in another position is a ninth toast there; the page evicts either way.
  if replacement.position ~= current.position then evictPosition(replacement.position) end
  State.put(replacement)
  send("update", State.payload(replacement))
  return response(true, { handle = replacement.handle, id = replacement.id })
end

---@param owner string
---@param handle any
---@return table
function Runtime.dismiss(owner, handle)
  local entry = State.get(handle)
  if entry == nil then return response(false, { error = "notification_not_found" }) end
  if entry.owner ~= owner then return response(false, { error = "not_owner" }) end
  removeInternal(entry.handle, "dismissed")
  return response(true, {})
end

---@param owner string
---@return table
function Runtime.clear(owner)
  return response(true, { removed = removeOwner(owner, "owner_cleared") })
end

---@param owner string
---@param value any
---@return table
function Runtime.setEnabled(owner, value)
  local enabled = State.setEnabled(owner, value)
  if not enabled then removeOwner(owner, "owner_disabled") end
  return response(true, { enabled = enabled })
end

---@param owner string
---@return table
function Runtime.list(owner)
  local handles = State.handlesOf(owner)
  table.sort(handles)
  local rows = {}
  for index = 1, #handles do
    rows[index] = State.payload(State.entries[handles[index]])
  end
  return response(true, { notifications = rows, count = #rows })
end

--- Note the caller's generation, dropping everything it held if it has reloaded.
---@param owner string
---@param generation integer
function Runtime.noteOwner(owner, generation)
  if State.generations[owner] ~= nil and State.generations[owner] ~= generation then
    removeOwner(owner, "owner_reloaded")
    State.enabled[owner] = nil
  end
  State.generations[owner] = generation
end

-- ---------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------

local nextOwnerSweepMs = 0

--- Drop the toasts of owners that have stopped or whose code has been replaced.
---@param atMs integer
local function sweepOwners(atMs)
  if atMs < nextOwnerSweepMs then return end
  nextOwnerSweepMs = atMs + OWNER_SWEEP_MS

  -- resolved once per sweep rather than twice per owner
  local generationOf
  if type(Open77.resource) == "table" and type(Open77.resource.generation) == "function" then
    generationOf = Open77.resource.generation
  end

  -- built lazily, and built at all because removing an owner mutates the table this walks
  local stopped, stoppedCount = nil, 0
  for owner, generation in pairs(State.generations) do
    local running = GetResourceState(owner) == "running"
    local current
    if generationOf ~= nil then current = generationOf(owner) end
    if not running or (current ~= nil and current ~= generation) then
      stoppedCount = stoppedCount + 1
      stopped = stopped or {}
      stopped[stoppedCount] = owner
    end
  end

  for index = 1, stoppedCount do
    local owner = stopped[index]
    removeOwner(owner, "owner_stopped")
    State.generations[owner] = nil
    State.enabled[owner] = nil
  end
end

--- Deadlines, then owners.
local function tick()
  local atMs = nowMs()

  local due, dueCount = nil, 0
  for handle, entry in pairs(State.entries) do
    if entry.expiresAtMs ~= nil and atMs >= entry.expiresAtMs then
      dueCount = dueCount + 1
      due = due or {}
      due[dueCount] = handle
    end
  end
  for index = 1, dueCount do removeInternal(due[index], "expired") end

  sweepOwners(atMs)
end

-- ---------------------------------------------------------------------------
-- What the server sends
-- ---------------------------------------------------------------------------

--- The four names the platform's server-side `Open77.notifications.*` fires. Every field is
--- re-derived here: these names sit on a bus any client can also raise locally.

RegisterNetEvent("open77:notifications:show", function(envelope)
  if type(envelope) ~= "table" then return end
  local owner = State.serverOwner(envelope.owner)
  if owner == nil then return end
  if not State.validName(envelope.id, 96) then return end
  if type(envelope.definition) ~= "table" then return end

  local definition = State.copy(envelope.definition)
  -- The envelope's id wins, and `replace` is forced: the server's record is keyed on it and
  -- a later `update` addresses that key.
  definition.id = envelope.id
  definition.replace = true
  Runtime.show(owner, definition)
end)

RegisterNetEvent("open77:notifications:update", function(envelope)
  if type(envelope) ~= "table" then return end
  local owner = State.serverOwner(envelope.owner)
  if owner == nil or type(envelope.patch) ~= "table" then return end
  if type(envelope.id) ~= "string" then return end
  local handle = State.identities[State.key(owner, envelope.id)]
  if handle == nil then return end
  Runtime.update(owner, handle, envelope.patch)
end)

RegisterNetEvent("open77:notifications:dismiss", function(envelope)
  if type(envelope) ~= "table" then return end
  local owner = State.serverOwner(envelope.owner)
  if owner == nil or type(envelope.id) ~= "string" then return end
  local handle = State.identities[State.key(owner, envelope.id)]
  if handle == nil then return end
  removeInternal(handle, "server_dismissed")
end)

--- The one envelope that is not a table: `notificationClear` sends the owner name alone.
RegisterNetEvent("open77:notifications:clear", function(ownerName)
  local owner = State.serverOwner(ownerName)
  if owner == nil then return end
  removeOwner(owner, "server_cleared")
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- The page has reported ready: push the config and replay everything held.
local function onPageReady()
  pageReady = true
  send("config", {
    position = Config.POSITION,
    width = Config.WIDTH,
  })
  -- handle order, oldest first: the page stacks in arrival order and evicts its first child
  local handles, count = {}, 0
  for handle in pairs(State.entries) do
    count = count + 1
    handles[count] = handle
  end
  table.sort(handles)
  for index = 1, count do send("add", State.payload(State.entries[handles[index]])) end
end

--- Run one loop pass under `pcall`. A raise from a host call would otherwise end the loop for
--- the session, and a loop that fails every pass must not write a line every pass either.
---@param label string
---@param body fun()
---@param failing boolean  whether the previous pass already failed
---@return boolean failing
local function guarded(label, body, failing)
  local ok, reason = pcall(body)
  if ok then return false end
  if not failing then Open77.log.error(("%s failed: %s"):format(label, tostring(reason))) end
  return true
end

AddEventHandler("onClientResourceStart", function(name)
  if name ~= RESOURCE then return end

  surfaceAttempted = true

  local reason
  page, reason = WebUI.create({
    entry = "web/index.html",
    -- "hud", never "menu" or "modal": this surface is never focused
    layer = "hud",
    width = 1920,
    height = 1080,
    fps = 30,
    -- the platform's own layer for toasts: above the hud and chat, below a menu
    zIndex = 720,
    transparent = true,
    -- Created visible: a `show()` right after `create` loses the race against this flag and
    -- the surface then never paints.
    visible = true,
  })

  if page == nil then
    Open77.log.error("WebUI surface failed: " .. tostring(reason))
    Open77.log.error("  no notification will be drawn; every export answers no_surface.")
    return
  end

  page:on(PAGE_READY, onPageReady)

  page:on(PAGE_DIAG, function(payload)
    if type(payload) ~= "table" then return end
    Open77.log.info("page: " .. tostring(payload.text or ""))
  end)

  CreateThread(function()
    local failing = false
    while true do
      failing = guarded("the toast tick", tick, failing)
      Wait(TICK_MS)
    end
  end)
end)

--- Our own stop takes the surface down; another resource's stop takes its toasts down now.
AddEventHandler("onClientResourceStop", function(name)
  if name == RESOURCE then
    -- Quiet: an owner's handler could call straight back into an export, and this VM is
    -- halfway through stopping.
    for handle in pairs(State.entries) do State.entries[handle] = nil end
    State.identities = {}
    State.generations = {}
    State.enabled = {}
    page, pageReady = nil, false
    -- The surface itself goes with the resource generation; teardown cleans it up.
    return
  end

  removeOwner(name, "owner_stopped")
  State.generations[name] = nil
  State.enabled[name] = nil
end)

--- Warns once if `open77_notifications` is also running. Deferred to a thread: at file scope
--- a resource listed after this one is still `discovered` and the warning would not fire.
CreateThread(function()
  local official = tostring(GetResourceState("open77_notifications") or ""):lower()
  if official ~= "running" and official ~= "starting" then return end
  Open77.log.warn("open77_notifications is running and is the package this one stands in for")
  Open77.log.warn("  both resources listen on the same four open77:notifications:* net")
  Open77.log.warn("  events and both publish the same export names, so every server-sent")
  Open77.log.warn("  toast is drawn twice, on two surfaces, in two corners. Drop one from")
  Open77.log.warn("  resources.load in server.jsonc.")
end)
