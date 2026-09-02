--- opx77_notify -- the surface, the sweep, and the four net events the platform's server
--- runtime already speaks.
---
--- The design point of this resource is in that last clause. The server side of OPEN//77
--- has no `exports` and no cross-resource event bus, so there can be no server-side
--- notification service; what the platform ships instead is `Open77.notifications.*` inside
--- every server VM's bootstrap, and that API does nothing but fire net events at the target.
--- Recovered from the shipped server binary, `notificationSend` is:
---
---     TriggerClientEvent("open77:notifications:show", target, {
---       owner = GetCurrentResourceName(), id = id, definition = definition,
---     })
---
--- and `update`, `dismiss` and `clear` are the same shape on `open77:notifications:update`,
--- `:dismiss` and `:clear` (clear carries the owner name alone, not a table). Nothing in it
--- names, checks for, or depends on the official `open77_notifications` client package: it
--- fires four names into the void and hopes something is listening. So this resource listens
--- for them, and every server resource already written against the standard API renders here
--- without changing a line.
---
--- The other half of the contract is the export surface in client/exports.lua, which carries
--- the same names the official package publishes.

OpxNotify = OpxNotify or {}

local Config = OPX_NOTIFY_CONFIG
local State = OpxNotify.state

local RESOURCE = GetCurrentResourceName()

--- How often deadlines are checked. The page animates its own lifetime bar from an absolute
--- deadline, so this cadence decides only how long a toast lingers after its bar empties.
local TICK_MS = 100

--- How often every owner is re-checked against the host. Stopping a resource already reaches
--- us through `onClientResourceStop`; this is the backstop for a generation that moved
--- without a stop we saw, and once a second is often enough for a backstop.
local OWNER_SWEEP_MS = 1000

--- The removal event the platform documents on its own package, raised on the client's local
--- bus with `TriggerEvent`. Code written against `open77_notifications` listens for exactly
--- this name, so it is the name we raise -- that is the whole point of mirroring a surface.
---
--- It is NOT one of the four `open77:notifications:*` wire names, and that separation is
--- deliberate: `TriggerEvent` also reaches `RegisterNetEvent` handlers of the same name --
--- the dispatcher matches on the name and ignores the network flag -- so raising a wire name
--- from inside its own handler would re-enter that handler forever. It is tick-paced rather
--- than stack recursion, so it would be a silent permanent busy loop with nothing logged.
local REMOVED_EVENT = "open77:notificationRemoved"

--- The same payload under this framework's own namespace, raised beside the one above so a
--- resource that already listens on the `opx77:` prefix does not have to learn a second one.
--- Both are local. A listener that registers for both hears about a removal twice.
local GLOBAL_EVENT = "opx77:notify:removed"

--- The WebUI IPC channels. These are `page:send` and `page:on` names, not event-bus names:
--- they travel a private pipe to this resource's own browser surface and cannot collide with
--- anything on the client's local bus.
local PAGE_READY = "notify:ready"
local PAGE_DIAG = "notify:diag"

local page = nil
local pageReady = false

--- Whether `WebUI.create` has been attempted yet, which is not the same question as whether
--- there is a page. Before `onClientResourceStart` runs there is no page and no failure
--- either, and an export that answered `no_surface` in that window would be refusing a call
--- it is about to be able to serve.
local surfaceAttempted = false

local Runtime = {}
OpxNotify.runtime = Runtime

local function nowMs()
  return math.floor(Open77.time.monotonic() * 1000)
end

---@param action string one of "config", "add", "update", "remove"
---@param value table|nil
local function send(action, value)
  if page ~= nil and pageReady then page:send("notify:" .. action, value or {}) end
end

-- ---------------------------------------------------------------------------
-- Removal, and the two events it raises
-- ---------------------------------------------------------------------------

--- Take one toast down and tell its owner why.
---
--- `quiet` suppresses both events, and exists for exactly one caller: this resource's own
--- stop. An owner's handler is free to call straight back into an export, and this VM is
--- halfway through stopping when that path runs.
---@param handle integer
---@param reason string
---@param quiet boolean|nil
---@return boolean
local function removeInternal(handle, reason, quiet)
  local entry = State.remove(handle)
  if entry == nil then return false end
  send("remove", { handle = handle, reason = reason })
  if quiet then return true end
  local payload = {
    handle = handle,
    id = entry.id,
    owner = entry.owner,
    reason = reason,
    data = entry.data,
  }
  TriggerEvent(REMOVED_EVENT, payload)
  TriggerEvent(GLOBAL_EVENT, payload)
  return true
end

---@param owner string
---@param reason string
---@param quiet boolean|nil
---@return integer removed
local function removeOwner(owner, reason, quiet)
  -- The handles are collected first: `removeInternal` mutates `State.entries`, and mutating
  -- the table a `pairs` loop is walking is undefined in Lua 5.4 for anything but assigning
  -- to a key that already exists.
  local handles = State.handlesOf(owner)
  local removed = 0
  for index = 1, #handles do
    if removeInternal(handles[index], reason, quiet) then removed = removed + 1 end
  end
  return removed
end

--- Make room in one position before a new toast joins it. The oldest goes, which is the
--- documented rule: "Adding a ninth toast to a position evicts its oldest toast."
---@param position string
local function evictPosition(position)
  local oldest, held = State.oldestAt(position)
  if held < State.MAX_PER_POSITION or oldest == nil then return end
  removeInternal(oldest.handle, "queue_limit")
end

-- ---------------------------------------------------------------------------
-- The operations, in terms of an owner that has already been established
-- ---------------------------------------------------------------------------

---@param ok boolean
---@param values table|nil
---@return table
local function response(ok, values)
  values = values or {}
  values.ok = ok == true
  return values
end

--- Whether a call would ever reach the page. `send` is silent when it would not; answering
--- `ok` for a toast nobody will ever see would be the one lie this file can tell. A page
--- that exists but has not reported ready is NOT a refusal: entries are held and replayed on
--- `notify:ready`, which is what the official package does too.
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
    -- Replacing in place, not adding: the ceilings guard additions, and the position this
    -- toast already occupies is one it is already counted in.
    if definition.replace ~= true then
      return response(false, { error = "duplicate_notification_id" })
    end
    local current = State.entries[existing]
    -- The stored entry is turned back into a definition and the incoming one merged over it,
    -- both in the same spelling: `State.canonical` collapses `kind`, `text` and `duration`
    -- onto `type`, `message` and `durationMs` first, or a definition that names an alias
    -- would sit beside the stored primary spelling and lose to it.
    local merged = State.definitionOf(current)
    for key, value in pairs(State.canonical(definition)) do merged[key] = value end
    local replacement, reason = State.normalize(owner, merged, existing, atMs)
    if replacement == nil then return response(false, { error = reason }) end
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
  -- keyed on it, and a renamed toast would leave its old key pointing at a live handle.
  merged.id = current.id

  -- A patch that says nothing about the deadline keeps the one it had, rather than silently
  -- restarting a countdown the caller did not mention. `normalize` computes `expiresAtMs`
  -- from `atMs` unconditionally, so this is put back afterwards.
  local touchesDuration = patch.durationMs ~= nil or patch.duration ~= nil

  local replacement, reason = State.normalize(owner, merged, current.handle, nowMs())
  if replacement == nil then return response(false, { error = reason }) end
  if not touchesDuration then
    replacement.createdAtMs = current.createdAtMs
    replacement.expiresAtMs = current.expiresAtMs
  end
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

--- Note the caller's generation, dropping everything it held if it has reloaded. The host
--- hands a generation over with every export call, so a reload is noticed on the first call
--- from the new VM rather than waiting for the sweep.
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

--- Owners whose resource has stopped or whose code has been replaced. `onClientResourceStop`
--- already covers the ordinary stop; this covers a generation that moved without one.
---@param atMs integer
local function sweepOwners(atMs)
  if atMs < nextOwnerSweepMs then return end
  nextOwnerSweepMs = atMs + OWNER_SWEEP_MS

  -- Resolved once for the sweep. It cannot change between two owners of the same pass, and
  -- inside the loop it was two `type` calls per owner every second.
  local generationOf
  if type(Open77.resource) == "table" and type(Open77.resource.generation) == "function" then
    generationOf = Open77.resource.generation
  end

  -- Built only when there is something to put in it, and built at all because removing an
  -- owner mutates the table this loop walks.
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

--- The four names the platform's server-side `Open77.notifications.*` fires, and the reason
--- this resource is a drop-in on the server side as well as the client side.
---
--- Every field is re-derived and type-checked here. `source` on the server cannot be forged,
--- but a payload can be, and these four names sit on the network bus where any client can
--- also raise them locally: the local dispatcher matches on the name and ignores the network
--- flag. `State.serverOwner` is the guard that matters -- it prefixes `@server:`, and `@` is
--- outside the character class `GetInvokingResource` values are validated against, so a
--- client resource can never hold a handle that a server envelope can address.

RegisterNetEvent("open77:notifications:show", function(envelope)
  if type(envelope) ~= "table" then return end
  local owner = State.serverOwner(envelope.owner)
  if owner == nil then return end
  if not State.validName(envelope.id, 96) then return end
  if type(envelope.definition) ~= "table" then return end

  local definition = State.copy(envelope.definition)
  -- The envelope's id wins over the definition's, because the server's own record is keyed
  -- on the envelope's and a later `update` addresses that key. `replace` is forced for the
  -- same reason: the server has already decided this id may be re-sent.
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

--- The one envelope that is not a table: the server's `notificationClear` sends
--- `GetCurrentResourceName()` as the whole payload.
RegisterNetEvent("open77:notifications:clear", function(ownerName)
  local owner = State.serverOwner(ownerName)
  if owner == nil then return end
  removeOwner(owner, "server_cleared")
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- The page, once it has told us it is listening. Everything held is replayed, because a
--- toast raised between `WebUI.create` and `notify:ready` is a toast `send` dropped.
local function onPageReady()
  pageReady = true
  send("config", {
    position = Config.POSITION,
    width = Config.WIDTH,
  })
  for _, entry in pairs(State.entries) do send("add", State.payload(entry)) end
end

AddEventHandler("onClientResourceStart", function(name)
  if name ~= RESOURCE then return end

  surfaceAttempted = true

  local reason
  page, reason = WebUI.create({
    entry = "web/index.html",
    -- "hud", never "menu" or "modal": this surface is never focused and must never be. A
    -- toast that took focus would take the keyboard away from a player mid-sentence.
    layer = "hud",
    width = 1920,
    height = 1080,
    -- 30, not 60. Nothing here animates per frame except one lifetime bar per toast, and
    -- the 2 ms client frame budget is shared with every other resource's surface.
    fps = 30,
    -- 720 is the platform's own number for toasts, above opx77_hud (705) and opx77_chat
    -- (700) and below opx77_menu (725): a notice that arrives while a menu is open is the
    -- one thing that may not cover the menu being driven.
    zIndex = 720,
    transparent = true,
    -- Created visible. Creation is asynchronous and a `show()` issued right after `create`
    -- loses the race against the `visible` flag the request carried, after which the surface
    -- never paints at all; the page shows and hides its own content instead.
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
    while true do
      tick()
      Wait(TICK_MS)
    end
  end)
end)

--- Both halves, as the first-party client services do it: our own stop has to take the whole
--- surface down, and another resource's stop takes its toasts down now rather than at the
--- next sweep.
AddEventHandler("onClientResourceStop", function(name)
  if name == RESOURCE then
    -- Quiet: no removal event for the toasts that just went. An owner's handler is free to
    -- call straight back into an export, and this VM is halfway through stopping.
    for handle in pairs(State.entries) do State.entries[handle] = nil end
    State.identities = {}
    State.generations = {}
    State.enabled = {}
    page, pageReady = nil, false
    -- The surface itself goes with the resource generation: `WebUI.Page.destroy`'s own
    -- documentation says "Resource teardown performs the same cleanup automatically". There
    -- is nothing to hand back either -- this page never takes focus.
    return
  end

  removeOwner(name, "owner_stopped")
  State.generations[name] = nil
  State.enabled[name] = nil
end)

--- Warns once if the official package this one stands in for is also running.
---
--- `GetResourceState` is the only way to ask. Deferred to a thread rather than run at file
--- scope, because at load time a conflicting resource listed after this one in
--- `resources.load` is still `discovered` and the warning would silently not fire -- which
--- would make it depend on load order, the one thing an operator did not choose. The host
--- answers lowercase; `:lower()` costs nothing and survives it changing.
CreateThread(function()
  local official = tostring(GetResourceState("open77_notifications") or ""):lower()
  if official ~= "running" and official ~= "starting" then return end
  Open77.log.warn("open77_notifications is running and is the package this one stands in for")
  Open77.log.warn("  both resources listen on the same four open77:notifications:* net")
  Open77.log.warn("  events and both publish the same export names, so every server-sent")
  Open77.log.warn("  toast is drawn twice, on two surfaces, in two corners. Drop one from")
  Open77.log.warn("  resources.load in server.jsonc.")
end)
