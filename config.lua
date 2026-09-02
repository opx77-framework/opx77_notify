OPX_NOTIFY_CONFIG = {
  -- Where a toast goes when its definition does not say.
  --
  -- THIS IS A DELIBERATE DEPARTURE. The official open77_notifications package defaults to
  -- "middle_left" (its client/main.lua: `local position = definition.position or
  -- "middle_left"`). Ours defaults to the top right, because that is where this framework's
  -- other surfaces already put transient notices: opx77_hud's info column is anchored
  -- "top-right" by default, and a player who has learned to read one corner for "something
  -- just happened" should not have to learn a second one. A caller that names a position
  -- explicitly still gets exactly the position it named, so a resource ported from the
  -- official package keeps its own placement.
  --
  -- The accepted set is the platform's, and only its -- there is no "middle_right" and no
  -- "middle_center": "top_left" | "top_center" | "top_right" | "middle_left" |
  -- "bottom_left" | "bottom_center" | "bottom_right". Anything else is refused with
  -- `invalid_position` rather than quietly corrected, because a toast in the wrong corner
  -- is a bug an operator would never find.
  POSITION = "top_right",

  -- How long a toast lives when its definition does not say, in milliseconds. `0` is
  -- persistent; any other value is clamped to 750..120000 by the platform's own schema, and
  -- a value outside that range is refused with `invalid_duration`. 5000 is the official
  -- package's default and there is no reason to differ.
  DURATION_MS = 5000,

  -- Whether a timed toast draws its lifetime bar when its definition does not say. A
  -- persistent toast (`durationMs = 0`) never draws one -- there is no lifetime to draw.
  PROGRESS = true,

  -- Toast width in pixels, at the 1920-wide surface the page is composited on. The stack
  -- never exceeds this, so a long message wraps rather than pushing into the middle of the
  -- screen.
  WIDTH = 340,
}
