--- The public surface: seven client exports. Every call answers a NotifyResponse and never
--- raises; the `error` codes are listed per export below and in README.md.

local State = OpxNotify.state
local Runtime = OpxNotify.runtime
local response = Runtime.response

--- Who is calling, and at which generation of their code, both read from the host so that a
--- caller cannot claim to be another resource.
---@return string|nil owner
---@return string|nil reason `export_call_required` when there is no invoking resource
local function caller()
  local owner = GetInvokingResource()
  local generation = GetInvokingResourceGeneration()
  if not State.validName(owner, State.MAX_OWNER) or type(generation) ~= "number" then
    return nil, "export_call_required"
  end
  -- A generation that has moved means the code that raised those toasts no longer exists.
  Runtime.noteOwner(owner, generation)
  return owner
end

--- Raise a toast. Answers the handle `update` and `dismiss` take.
---@param definition NotifyDefinition
---@return NotifyResponse # error: export_call_required, no_surface, owner_disabled,
--- duplicate_notification_id, notification_limit, or any of the definition's validation
--- codes, which README.md lists
exports("show", function(definition)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.show(owner, definition)
end)

--- Change one of yours in place. A patch that says nothing about the duration keeps the
--- deadline the toast already had.
---@param handle integer the handle `show` answered
---@param patch NotifyDefinition fields absent from it keep the value they have
---@return NotifyResponse # error: export_call_required, no_surface, notification_not_found,
--- not_owner, patch_must_be_a_table, or any of `show`'s validation codes
exports("update", function(handle, patch)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.update(owner, handle, patch)
end)

--- Take one of yours down now.
---@param handle integer
---@return NotifyResponse # error: export_call_required, notification_not_found, not_owner
exports("dismiss", function(handle)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.dismiss(owner, handle)
end)

--- Take down every toast of yours. Holding none is not an error.
---@return NotifyResponse # error: export_call_required
exports("clear", function()
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.clear(owner)
end)

--- Your live toasts, oldest handle first. Only ever yours.
---@return NotifyResponse # error: export_call_required
exports("list", function()
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.list(owner)
end)

--- Turn your own toasts off, or back on. Disabling clears everything you hold and suppresses
--- what you send until you enable again. Per caller, not global.
---@param value any anything but `false` enables
---@return NotifyResponse # error: export_call_required
exports("setEnabled", function(value)
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return Runtime.setEnabled(owner, value)
end)

--- Whether your own toasts are on. An owner that has never called `setEnabled` is enabled.
---@return NotifyResponse # error: export_call_required
exports("isEnabled", function()
  local owner, reason = caller()
  if owner == nil then return response(false, { error = reason }) end
  return response(true, { enabled = State.isEnabled(owner) })
end)
