resource "opx77_notify"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- "reconnect", like every resource that owns a CEF surface.
--
-- The rule is the platform's, not ours: a resource that owns a WebUI surface declares
-- "reconnect"; one that owns only rules or state declares "local". Swapping a live CEF
-- surface while gameplay is running has historically caused unstable transitions, so a
-- generation change takes the session through a clean reconnect instead of replacing the
-- page in place. writing-a-gamemode.md states it in one line: "A WebUI surface needs
-- reload_policy 'reconnect'; a rules resource wants 'local'." The package this one stands
-- in for, open77_notifications, declares it too and gives the same reason in its own
-- manifest: "The surface is never replaced in-place. A server generation change uses a
-- clean reconnect, matching the other shared CEF services."
reload_policy "reconnect"

-- Load order is the contract: config publishes OPX_NOTIFY_CONFIG, state.lua reads it and
-- publishes the store, main.lua drives the surface and the wire, and exports.lua goes last
-- because publishing the surface claims it exists.
client_script "config.lua"
client_script "client/state.lua"
client_script "client/main.lua"
client_script "client/exports.lua"

-- No server_script, and there is deliberately no server half. The server runtime installs
-- no `exports` and no cross-resource event bus, so a server-side notification service could
-- not be called by anything; the platform already solves that in its own bootstrap, whose
-- `Open77.notifications.*` does nothing but fire the four `open77:notifications:*` net
-- events this resource listens for. See README.md.

web_ui_page "web/index.html"
web_ui_auto_create false -- client/main.lua creates it, so a failure is one logged line
-- `**` on its own is the one glob that is safe here. The fatal pattern is a SCRIPT glob:
-- `client/**/*.lua` needs an intermediate directory and matches nothing against a flat
-- `client/`, and an empty script pattern refuses the whole session's resource set with
-- `script_pattern_empty:...` -- no player can connect. That is why every script above is
-- on its own line. `web_files { "web/**" }` is not that case: it is what fifteen shipped
-- resources use, including open77_chat and open77_notifications, and the server's own
-- package cache shows it matching this resource's flat web/ files one for one.
web_files { "web/**" }

permissions {
  -- Inbound only, and only four names: `open77:notifications:show`, `:update`, `:dismiss`
  -- and `:clear`, which is the entire wire vocabulary the platform's server-side
  -- `Open77.notifications.*` emits. `RegisterNetEvent` needs this grant; nothing here ever
  -- calls `TriggerServerEvent`, and there is no server half to call.
  "network.events",
}

-- Nothing else is declared on purpose, not by omission. The surface is never focused --
-- `pointer-events: none`, no `setFocus` call anywhere -- so no `webui.*` grant applies; the
-- exports need none on either side; and no world, input or environment API is touched.
