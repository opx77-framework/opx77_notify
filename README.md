# opx77_notify

> [!WARNING]
> **This project is currently in early development and is not considered production-ready.**
>
> The API, architecture, features, and internal systems are subject to change at any time without prior notice. Breaking changes may be introduced as development progresses.
>
> **Do not rely on the current API for production resources yet.**

The toast service for **Opx77**: one surface, owned by this resource, that any other resource can put a notice on.

It is client-side, because that is the only side exports exist on — the OPEN//77 server runtime installs no `exports` and no `GetInvokingResource`, so a server-side notification service could not be called by anything.

## Drop-in on both sides

This is the part worth reading before anything else, because it is why this resource exists in the shape it does.

**A server resource that already uses the standard API needs no change.** The platform's server Lua bootstrap ships `Open77.notifications.send`, `broadcast`, `update`, `dismiss` and `clear` inside every server VM. Recovered from the shipped server binary, all any of them does is fire a net event at the target:

```lua
TriggerClientEvent("open77:notifications:show", target, {
  owner = GetCurrentResourceName(), id = id, definition = definition,
})
```

and `update`, `dismiss` and `clear` are the same shape on `open77:notifications:update`, `:dismiss` and `:clear`. Nothing in that code names, checks for, or depends on the official `open77_notifications` client package — it fires four names and hopes something is listening. **`opx77_notify` listens for those four names**, so a server resource written against `Open77.notifications.*` renders in OPX//77's toasts without changing a line.

**A client resource written against the official export names needs no change either.** The exports below are the names the platform documents on its own package, with the same arguments, the same definition schema and the same limits.

> [!WARNING]
> **Do not run this and `open77_notifications` at the same time.**
>
> Both listen on the same four `open77:notifications:*` net events and both publish the same export names, so every server-sent toast is drawn twice, on two surfaces, in two corners. The resource warns about it in the client log at start; drop one of the two from `resources.load` in `server.jsonc`.

## Features

- Four kinds — `info`, `success`, `warning`, `error` — each with its own accent
- A title and a body, both rendered: the title is the heading, the body the line under it
- Seven positions, timed or persistent toasts, and a lifetime bar the page animates itself
- Ownership per calling resource: a resource only ever touches its own toasts
- Toasts go on their own when their owner stops, reloads, or turns itself off
- A transparent surface that never takes focus and never captures the cursor

## Top right, not middle left

`OPX_NOTIFY_CONFIG.POSITION` defaults to `"top_right"`. The official package defaults to `"middle_left"`.

This is a deliberate departure and the only default that differs. The top right is where this framework's other surfaces already put transient notices — `opx77_hud`'s info column is anchored there by default — and a player who has learned to read one corner for "something just happened" should not have to learn a second one. A caller that names a `position` explicitly still gets exactly the position it named, so a resource ported from the official package keeps its own placement.

## Commands

None. It carries everybody else's notices and registers nothing of its own.

## Exports

Client-side, and deliberately the names the platform documents on its own `open77_notifications` package, with the same arguments — code written against the documented notification surface works here without a change.

| Export | Does |
|---|---|
| `show(definition)` | raise a toast; answers the handle `update` and `dismiss` take |
| `update(handle, patch)` | change one of yours in place |
| `dismiss(handle)` | take one of yours down now |
| `clear()` | take all of yours down |
| `list()` | your live toasts, oldest handle first |
| `setEnabled(enabled)` | turn your own toasts off, or back on |
| `isEnabled()` | whether yours are on |

Every call answers `{ ok = boolean }`, with an `error` code when `ok` is false. The official package returns bare booleans from `isEnabled` and a bare array from `list`; a caller that only tests truthiness reads `{ ok = true }` as true either way, and one that wants the reason now has it. Every code is listed in the header of `client/exports.lua` and on the documentation site.

The caller is read from the host with `GetInvokingResource()`, never from an argument: there is no parameter anywhere on this surface that names an owner, so a resource cannot claim to be another one.

Like every export on this platform the call is asynchronous, so it answers a promise and has to be awaited inside a `CreateThread`. Failure has three levels and they mean different things: the call was never dispatched, it was dispatched and could not resolve, or it resolved into a refusal — only the last one is authoritative.

```lua
CreateThread(function()
  local promise, reason = Open77.exports.call("opx77_notify", "show", {
    id = "job_started",
    type = "success",
    title = "Mission accepted",
    message = "Meet the fixer at the Kabuki garage.",
    icon = "JOB",
    durationMs = 5000,
  })
  if not promise then return print("not dispatched: " .. tostring(reason)) end

  local answer, callError = promise:await()
  if callError then return print("call failed: " .. tostring(callError)) end
  if not answer.ok then return print("notify refused: " .. tostring(answer.error)) end

  print("toast handle " .. tostring(answer.handle))
end)
```

## The definition

| Field | Meaning |
|---|---|
| `id` | Optional stable owner-local id, up to 96 characters of `[%w_:%-%.]`. |
| `replace` | Replace an existing toast of yours with the same `id` when `true`. |
| `type` / `kind` | `info`, `success`, `warning` or `error`; defaults to `info`. |
| `title` | Optional heading, up to 96 UTF-8 bytes. |
| `message` / `text` | Required body, up to 384 UTF-8 bytes. |
| `icon` | Optional short textual badge, up to 16 UTF-8 bytes. |
| `position` | One of the platform's seven; defaults to `OPX_NOTIFY_CONFIG.POSITION`. |
| `durationMs` / `duration` | `0` is persistent; a timed value is 750–120000. |
| `progress` | Draw the lifetime bar. Ignored when persistent. |
| `color` | Optional `#RRGGBB` accent, overriding the kind's. |
| `data` | Opaque, echoed back in the removal event. |

At most **32** toasts are held at once and at most **eight per position**; adding a ninth to a position evicts that position's oldest. Those are the platform's numbers, not ours — loosening them would make this resource behave differently from the package it stands in for.

## Events

Both are **local**, raised with `TriggerEvent` on the client's host-wide bus and received with a bare `AddEventHandler`. Neither is a wire name.

| Event | Raised |
|---|---|
| `open77:notificationRemoved` | whenever a toast goes away, for every owner |
| `opx77:notify:removed` | the same payload, under this framework's namespace |

The payload carries `handle`, `id`, `owner`, `reason` and `data`. Reasons are `expired`, `dismissed`, `queue_limit`, `owner_cleared`, `owner_disabled`, `owner_reloaded`, `owner_stopped`, `server_dismissed` and `server_cleared`.

A listener registered for both hears about one removal twice. Pick one.

## Configuration

`config.lua`. Where a toast goes when its definition does not say, how long it lives, whether it draws a lifetime bar, and how wide the stack is.

## Community & Support

Join the Open77 and Opx77 communities to discover the platform, share your projects, and connect with other developers.

<!-- TODO: replace with the final URLs before publication. -->

* [Open77](#)
* [Open77 GitHub](#)
* [OPX Discord](#)

## License

opx77_notify is licensed under the [**MIT License**](LICENSE).

Copyright © 2026 **Luis MOUTA**.

<p align="center">
    <sub>opx77_notify is an independent community project and is not affiliated with or endorsed by CD PROJEKT RED.</sub>
</p>
