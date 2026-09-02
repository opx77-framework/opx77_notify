resource "opx77_notify"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true

-- Swapping a live CEF surface mid-session is unstable, so a generation change reconnects.
reload_policy "reconnect"

-- Load order is manifest order: config publishes OPX_NOTIFY_CONFIG, state the store, main
-- the surface and the wire, exports last.
client_script "config.lua"
client_script "client/state.lua"
client_script "client/main.lua"
client_script "client/exports.lua"

-- No server half: the server runtime installs no exports and no cross-resource event bus.

web_ui_page "web/index.html"
web_ui_auto_create false -- client/main.lua creates it, so a failure is one logged line
web_files { "web/**" }

permissions {
  -- RegisterNetEvent for the four inbound open77:notifications:* names; nothing here ever
  -- calls TriggerServerEvent
  "network.events",
}
