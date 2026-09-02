--- Defaults for the toast surface, read by client/state.lua and client/main.lua.

OPX_NOTIFY_CONFIG = {
  -- Where a toast goes when its definition does not say. One of the platform's seven
  -- positions; anything else is refused with `invalid_position`.
  POSITION = "top_right",

  -- How long a toast lives when its definition does not say, in milliseconds.
  -- `0` is persistent; a timed value is 750..120000.
  DURATION_MS = 5000,

  -- Whether a timed toast draws its lifetime bar when its definition does not say.
  PROGRESS = true,

  -- Toast width in pixels, at the 1920-wide surface the page is composited on.
  WIDTH = 340,
}
