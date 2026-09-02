--- opx77_notify -- the public surface.
---
--- These are the names the platform documents on its own `open77_notifications` package
--- (`notifications.md`, and the shipped `client/main.lua` behind it): `show`, `update`,
--- `dismiss`, `clear`, `list`, `setEnabled` and `isEnabled`. Same arguments, same definition
--- schema, same ownership rule, same limits -- so third-party code written against the
--- documented notification surface works against this resource without a change.
---
--- Client-side, because that is the only side exports exist on: the server runtime installs
--- none, and no `GetInvokingResource` either. A server resource that wants to put a toast on
--- one player's screen calls the platform's own `Open77.notifications.send`, which fires
--- `open77:notifications:show` at that player -- the net-event half of client/main.lua is
--- what receives it.
---
--- Every call answers a table carrying `ok` and never raises, which is this framework's
--- convention and opx77_core's. The official package returns bare booleans from `isEnabled`
--- and a bare array from `list`; a caller that only tests truthiness reads `{ ok = true }` as
--- true either way, and one that wants the reason now has it. `error` is a stable snake_case
--- code meant for branching, and this is every code these seven can answer:
---
---   export_call_required      called from inside this resource, or without the export
---                             machinery -- there is no invoking resource to attribute the
---                             call to, and an argument naming an owner would be forgeable
---   no_surface                WebUI.create failed at start; there is no page and never will
---                             be for this generation. A page that exists but has not yet
---                             reported ready is NOT this: the toast is held and replayed
---   owner_disabled            you called setEnabled(false) and have not called it back on
---   definition_must_be_a_table  the definition (or the replacement) is not a table
---   patch_must_be_a_table     the patch handed to `update` is not a table
---   invalid_type              `type`/`kind` is not info, success, warning or error
---   invalid_notification_id   `id` is not 1..96 characters of [%w_:%-%.]
---   invalid_title             `title` is over 96 bytes, not a string, or has a control char
---   invalid_message           `message`/`text` is missing, empty, over 384 bytes, not a
---                             string, or has a control character
---   invalid_icon              `icon` is over 16 bytes, not a string, or has a control char
---   invalid_position          `position` is not one of the platform's seven
---   invalid_duration          `durationMs`/`duration` is not 0 and not an integer in
---                             750..120000
---   invalid_progress          `progress` is present and is not a boolean
---   invalid_color             `color` is present and is not `#RRGGBB`
---   data_too_large            `data` is a table over 64 nodes or 4 levels deep
---   duplicate_notification_id you already hold this id and did not pass `replace = true`
---   notification_limit        32 toasts are already held, across every owner
---   notification_not_found    no live toast has that handle
---   not_owner                 that handle belongs to another resource
---
--- There is deliberately no code for "the page has not loaded yet" and no code for a handle
--- that is not a number: the first is not a failure, and the second is `notification_not_found`
--- because that is what the official package answers and portability is the point.

local State = OpxNotify.state
local Runtime = OpxNotify.runtime

---@param ok boolean
---@param values table|nil
---@return table
local function response(ok, values)
  values = values or {}
  values.ok = ok == true
  return values
end

--- Who is calling, and at which generation of their code, both from the host.
---
--- Never from an argument: a caller must not be able to claim to be another resource, and
--- there is no parameter anywhere on this surface that names an owner. Nothing inside this
--- VM should be reaching the public surface either -- `OpxNotify.runtime` is right there --
--- so a call with no invoking resource is a call that went somewhere it did not mean to.
---@return string|nil owner
---@return string|nil reason the refusal code when owner is nil
local function caller()
  local owner = GetInvokingResource()
  local generation = GetInvokingResourceGeneration()
  if not State.validName(owner, 64) or type(generation) ~= "number" then
    return nil, "export_call_required"
  end
  -- A generation that has moved means the code that raised those toasts no longer exists,
  -- so they go before this call is served rather than at the next sweep.
  Runtime.noteOwner(owner, generation)
  return owner
end


---@alias NotifyKind "info"|"success"|"warning"|"error"
---@alias NotifyPosition
---| "top_left" | "top_center" | "top_right"
---| "middle_left"
---| "bottom_left" | "bottom_center" | "bottom_right"

--- Raise a toast. Answers the handle `update` and `dismiss` take.
---@param definition NotifyDefinition
---@return table
exports("show", function(definition)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.show(owner, definition)
end)

--- Change one of yours in place. A patch that says nothing about the duration keeps the
--- deadline the toast already had, so the bar does not restart under a changed message.
---@param handle integer the handle `show` answered
---@param patch NotifyDefinition fields absent from it keep the value they have
---@return table
exports("update", function(handle, patch)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.update(owner, handle, patch)
end)

--- Take one of yours down now. Dismissing what is not there is `notification_not_found`,
--- never a raise.
---@param handle integer
---@return table
exports("dismiss", function(handle)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.dismiss(owner, handle)
end)

--- Take down every toast of yours. Never touches another resource's, and holding none is not
--- an error.
---@return table
exports("clear", function()
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.clear(owner)
end)

--- Your live toasts, oldest handle first. Only ever yours: a resource cannot inspect,
--- update or dismiss another owner's entries.
---@return table
exports("list", function()
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.list(owner)
end)

--- Turn your own toasts off, or back on. Disabling clears everything you hold and suppresses
--- what you send until you enable again.
---
--- Per caller, not global -- and that is the official package's rule, not ours. It is the
--- opposite of `opx77_chat`'s `setEnabled`, which is one flag for the whole box: a chat is
--- one surface a cutscene turns off, whereas a toast stack is many resources' and no one of
--- them gets to silence the others.
---@param value any anything but `false` enables
---@return table ok, and the state it now holds
exports("setEnabled", function(value)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.setEnabled(owner, value)
end)

--- Whether your own toasts are on. An owner that has never called `setEnabled` is enabled.
---@return table ok, and the current state
exports("isEnabled", function()
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return response(true, { enabled = State.isEnabled(owner) })
end)
