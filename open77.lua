resource "opx77_notify"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- A resource that owns a WebUI surface declares "reconnect"; a rules resource declares "local".
reload_policy "reconnect"

-- Load order is the contract: config publishes OPX_NOTIFY_CONFIG, state publishes the store,
-- main drives the surface and the wire, exports goes last.
-- Scripts are listed one per line on purpose: a script glob that matches nothing refuses the
-- whole session's resource set with `script_pattern_empty`.
client_script "config.lua"
client_script "client/state.lua"
client_script "client/main.lua"
client_script "client/exports.lua"

-- No server half: the server runtime installs no exports and no cross-resource event bus.

web_ui_page "web/index.html"
web_ui_auto_create false -- client/main.lua creates it, so a failure is one logged line
web_files { "web/**" }

permissions {
  -- RegisterNetEvent for the four inbound `open77:notifications:*` names. Nothing here ever
  -- calls TriggerServerEvent.
  "network.events",
}
