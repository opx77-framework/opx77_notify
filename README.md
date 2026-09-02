# opx77_notify

> [!WARNING]
> **This project is currently in early development and is not considered production-ready.**
>
> The API, architecture, features, and internal systems are subject to change at any time without prior notice. Breaking changes may be introduced as development progresses.
>
> **Do not rely on the current API for production resources yet.**

The toast service for **Opx77**: one surface, owned by this resource, that any other resource can put a notice on.

It is client-side, because that is the only side exports exist on — the OPEN//77 server runtime installs no `exports` and no `GetInvokingResource`.

## Drop-in on both sides, with one break

A server resource that already uses `Open77.notifications.send`, `broadcast`, `update`, `dismiss` or `clear` needs no change: those functions do nothing but fire the four `open77:notifications:show` / `:update` / `:dismiss` / `:clear` net events at the target, and this resource listens for exactly those names.

A client resource written against the official export names needs no change either: the exports below are the names the platform documents on its own `open77_notifications` package, with the same arguments, the same definition schema and the same limits.

> [!IMPORTANT]
> **The break: `open77:notificationRemoved` is not raised.** That is the name the platform documents for its own `open77_notifications` package. This resource raises [`opx77:notify:removed`](#events) instead, with the same payload and the same reasons. A resource listening for the platform's name hears nothing about a removal and has to be pointed at `opx77:notify:removed`. Everything else is unchanged: the four inbound net events, the export names, their arguments, the definition schema and the limits.

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

## Commands

None. It carries everybody else's notices and registers nothing of its own.

## Exports

Client-side, and deliberately the names the platform documents on its own `open77_notifications` package, with the same arguments.

| Export | Does |
|---|---|
| `show(definition)` | raise a toast; answers the handle `update` and `dismiss` take |
| `update(handle, patch)` | change one of yours in place |
| `dismiss(handle)` | take one of yours down now |
| `clear()` | take all of yours down |
| `list()` | your live toasts, oldest handle first |
| `setEnabled(enabled)` | turn your own toasts off, or back on |
| `isEnabled()` | whether yours are on |

The caller is read from the host with `GetInvokingResource()`, never from an argument: no parameter on this surface names an owner, so a resource cannot claim to be another one. Every toast belongs to the resource that raised it — `update`, `dismiss`, `clear` and `list` only ever reach your own, and `setEnabled` is per caller, not global.

Every call answers `{ ok = boolean }`, with an `error` code when `ok` is false. The official package returns bare booleans from `isEnabled` and a bare array from `list`; a caller that only tests truthiness reads `{ ok = true }` as true either way.

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

### Error codes

| Code | Means |
|---|---|
| `export_call_required` | called from inside this resource, or without the export machinery, so there is no invoking resource to attribute the call to |
| `no_surface` | `WebUI.create` failed at start; there is no page and never will be for this generation. A page that exists but has not yet reported ready is not this: the toast is held and replayed |
| `owner_disabled` | you called `setEnabled(false)` and have not called it back on |
| `definition_must_be_a_table` | the definition (or the replacement) is not a table |
| `patch_must_be_a_table` | the patch handed to `update` is not a table |
| `invalid_type` | `type`/`kind` is not `info`, `success`, `warning` or `error` |
| `invalid_notification_id` | `id` is not 1..96 characters of `[%w_:%-%.]` |
| `invalid_title` | `title` is over 96 bytes, not a string, or has a control character |
| `invalid_message` | `message`/`text` is missing, empty, over 384 bytes, not a string, or has a control character |
| `invalid_icon` | `icon` is over 16 bytes, not a string, or has a control character |
| `invalid_position` | `position` is not one of the seven |
| `invalid_duration` | `durationMs`/`duration` is not `0` and not an integer in 750..120000 |
| `invalid_progress` | `progress` is present and is not a boolean |
| `invalid_color` | `color` is present and is not `#RRGGBB` |
| `data_too_large` | `data` is a table over 64 nodes or 4 levels deep |
| `duplicate_notification_id` | you already hold this id and did not pass `replace = true` |
| `notification_limit` | 32 toasts are already held, across every owner |
| `notification_not_found` | no live toast has that handle |
| `not_owner` | that handle belongs to another resource |

There is no code for "the page has not loaded yet" — that is not a failure — and a handle that is not a number answers `notification_not_found`, as the official package does.

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
| `data` | Opaque, echoed back in the removal event. At most 64 nodes, 4 levels deep. |

Where both spellings of an aliased field are present the primary one wins: `type` over `kind`, `message` over `text`, `durationMs` over `duration`. A patch handed to `update` that says nothing about the duration keeps the deadline the toast already had.

At most **32** toasts are held at once and at most **eight per position**; adding a ninth to a position evicts that position's oldest. Those are the platform's numbers.

The seven positions are `top_left`, `top_center`, `top_right`, `middle_left`, `bottom_left`, `bottom_center` and `bottom_right`. There is no `middle_right` and no `middle_center`.

## Events

One event, `opx77:notify:removed`, raised whenever a toast goes away, for every owner. It is **local**: raised with `TriggerEvent` on the client's host-wide bus and received with a bare `AddEventHandler`. It is not a wire name.

```lua
AddEventHandler("opx77:notify:removed", function(payload) end)
```

The payload carries `handle`, `id`, `owner`, `reason` and `data`. Reasons are `expired`, `dismissed`, `queue_limit`, `owner_cleared`, `owner_disabled`, `owner_reloaded`, `owner_stopped`, `server_dismissed` and `server_cleared`. `owner` is the raising resource's name, or `@server:<resource>` for a server-sent toast.

The platform's `open77:notificationRemoved` is **not** raised — see [Drop-in on both sides, with one break](#drop-in-on-both-sides-with-one-break).

## Configuration

`config.lua`. Where a toast goes when its definition does not say, how long it lives, whether it draws a lifetime bar, and how wide the stack is.

`POSITION` defaults to `"top_right"`, where this framework's other surfaces put transient notices; the official package defaults to `"middle_left"`. It is the only default that differs, and a caller that names a `position` explicitly still gets the one it named.

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
