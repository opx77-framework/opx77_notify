/* opx77_notify -- the page.
 *
 * A renderer and nothing else. Lua decides which toasts exist, what they say, where they
 * go and when they end; this draws them and animates one lifetime bar each. The only
 * outbound channels are `notify:ready` and a diagnostic one.
 */
(function () {
  "use strict";

  /* CEF console output does not reach the client log, and the WebUI bridge swallows every
     exception thrown inside an `Open77.on` handler. Without this, a throw in here is
     invisible from the server console. */
  var reportCount = 0;
  var reporting = false;

  function describe(value) {
    try {
      if (value instanceof Error) return (value.name || "Error") + ": " + value.message;
      if (value === null || value === undefined) return String(value);
      if (typeof value === "object") return Object.prototype.toString.call(value);
      return String(value);
    } catch (ignored) { return "<undescribable>"; }
  }

  function report(text) {
    if (reporting || reportCount >= 20) return;
    reporting = true;
    reportCount += 1;
    try { window.Open77.emit("notify:diag", { text: String(text).slice(0, 400) }); }
    catch (ignored) { /* nowhere left to complain to */ }
    reporting = false;
  }

  window.addEventListener("error", function (event) {
    report("uncaught " + (event.message || "?") + " at line " + (event.lineno || 0));
  });
  (function (original) {
    console.error = function () {
      report(Array.prototype.map.call(arguments, describe).join(" "));
      try { original.apply(console, arguments); } catch (ignored) { /* no console */ }
    };
  })(console.error);

  function text(value) { return value === null || value === undefined ? "" : String(value); }

  /* The seven the schema defines, and the four kinds. Both are closed sets: an unrecognised
     value falls back rather than reaching a class name, so nothing Lua sends can invent a
     selector. */
  var POSITIONS = ["top_left", "top_center", "top_right", "middle_left",
                   "bottom_left", "bottom_center", "bottom_right"];
  var KINDS = { info: true, success: true, warning: true, error: true };

  /* Written straight into a custom property, so it is matched before it is written. */
  var HEX = /^#[0-9a-fA-F]{6}$/;

  /* The page's own ceilings, independent of Lua's. Lua holds at most 32 toasts and at most
     eight per position; these repeat those numbers here because a renderer that trusts its
     sender for its own memory bound has no bound. */
  var MAX_PER_STACK = 8;
  var MAX_TOTAL = 32;

  /* How long a leaving toast stays in the DOM so its exit transition can run. It must be at
     least as long as --op77-dur-slow in open77-ui.css, and it is not a visual constant: a
     shorter value would delete the node mid-transition. */
  var EXIT_MS = 260;

  var stacks = {};
  for (var index = 0; index < POSITIONS.length; index += 1) {
    stacks[POSITIONS[index]] = document.getElementById("stack_" + POSITIONS[index]);
  }

  var settings = { position: "top_right" };

  /* handle -> { node, title, message, icon, bar, position, endsAt, totalMs, leaving } */
  var toasts = {};
  var liveCount = 0;

  function stackFor(position) {
    return stacks[position] || stacks[settings.position] || stacks.top_right;
  }

  function span(className) {
    var node = document.createElement("span");
    node.className = className;
    return node;
  }

  function applyConfig(payload) {
    payload = payload || {};
    var position = text(payload.position);
    if (stacks[position] !== undefined) settings.position = position;
    var width = Number(payload.width);
    if (isFinite(width) && width > 0) {
      document.documentElement.style.setProperty("--toast-width", Math.round(width) + "px");
    }
  }

  /* One element per handle, kept for as long as Lua keeps that handle: rebuilding it on an
     update would restart the entrance animation and the countdown. */
  function toast(handle) {
    var entry = toasts[handle];
    if (entry !== undefined && !entry.leaving) return entry;

    /* A handle whose node is on its way out is replaced rather than reused: the old node is
       mid-transition and re-entering it would leave the exit class on a live toast. */
    if (entry !== undefined && entry.leaving) drop(handle, true);

    entry = {
      node: document.createElement("article"),
      icon: span("icon"),
      title: span("title"),
      message: span("message"),
      bar: span("bar"),
      position: null,
      endsAt: null,
      totalMs: null,
      leaving: false
    };
    var body = document.createElement("div");
    body.className = "body";
    body.appendChild(entry.title);
    body.appendChild(entry.message);
    entry.node.appendChild(entry.icon);
    entry.node.appendChild(body);
    entry.node.appendChild(entry.bar);
    toasts[handle] = entry;
    liveCount += 1;
    return entry;
  }

  /* Take a node out now (`immediate`) or after its exit transition. `immediate` is for
     eviction and for replacing a leaving handle, where there is nothing to animate. */
  function drop(handle, immediate) {
    var entry = toasts[handle];
    if (entry === undefined) return;
    if (!entry.leaving) {
      entry.leaving = true;
      liveCount -= 1;
    }
    delete toasts[handle];
    var node = entry.node;
    if (immediate) {
      if (node.parentNode) node.remove();
      return;
    }
    node.classList.add("out");
    window.setTimeout(function () {
      try { if (node.parentNode) node.remove(); }
      catch (error) { report("drop: " + describe(error)); }
    }, EXIT_MS);
  }

  /* The page's own eviction, matching Lua's rule: the oldest in this stack goes. `children`
     is in insertion order and a leaving node is skipped, so the oldest LIVE node is the
     first child that is not on its way out. */
  function evict(stack) {
    var live = 0;
    var oldest = null;
    for (var i = 0; i < stack.children.length; i += 1) {
      var node = stack.children[i];
      if (node.classList.contains("out")) continue;
      live += 1;
      if (oldest === null) oldest = node;
    }
    if (live < MAX_PER_STACK || oldest === null) return;
    for (var handle in toasts) {
      if (toasts[handle].node === oldest) { drop(handle, true); return; }
    }
    oldest.remove();
  }

  function apply(entry, row) {
    var kind = text(row.type);
    if (KINDS[kind] !== true) kind = "info";
    entry.node.className = "toast " + kind;

    var color = text(row.color);
    if (HEX.test(color)) entry.node.style.setProperty("--accent", color);

    var icon = text(row.icon);
    entry.icon.textContent = icon;
    entry.icon.hidden = icon === "";

    var title = text(row.title);
    entry.title.textContent = title;
    entry.title.hidden = title === "";

    entry.message.textContent = text(row.message);

    /* Absolute, so the countdown is this page's own arithmetic from here on. Lua sends a
       duration, never a remaining time: the two clocks never have to agree. */
    var durationMs = Number(row.durationMs);
    var timed = row.progress === true && isFinite(durationMs) && durationMs > 0;
    entry.totalMs = timed ? durationMs : null;
    entry.endsAt = timed ? Date.now() + durationMs : null;
    entry.bar.hidden = !timed;
    if (!timed) entry.bar.style.width = "0";
  }

  function add(row) {
    row = row || {};
    var handle = Number(row.handle);
    if (!isFinite(handle)) return;

    /* Lua's ceiling is 32 and it refuses past it, so reaching this one means something else
       is talking to this page. Dropping the incoming toast is the safe direction: it keeps
       what is already on screen readable rather than churning it. */
    if (toasts[handle] === undefined && liveCount >= MAX_TOTAL) return;

    var position = text(row.position);
    if (stacks[position] === undefined) position = settings.position;
    var stack = stackFor(position);

    var entry = toast(handle);
    apply(entry, row);

    if (entry.position !== position || entry.node.parentNode !== stack) {
      entry.position = position;
      evict(stack);
      stack.appendChild(entry.node);
    }
    pump();
  }

  function update(row) {
    row = row || {};
    var handle = Number(row.handle);
    if (!isFinite(handle)) return;
    var entry = toasts[handle];
    /* An update for a handle this page never drew is an add. It happens when a surface is
       created after a toast was raised, or after this page reloaded under a live resource. */
    if (entry === undefined || entry.leaving) { add(row); return; }
    apply(entry, row);

    var position = text(row.position);
    if (stacks[position] === undefined) position = settings.position;
    if (entry.position !== position) {
      entry.position = position;
      var stack = stackFor(position);
      evict(stack);
      stack.appendChild(entry.node);
    }
    pump();
  }

  /* One rAF loop for every bar on screen; it stops itself once none of them has a deadline
     left to draw. */
  var pending = false;

  function frame() {
    var atMs = Date.now();
    var running = false;
    for (var handle in toasts) {
      var entry = toasts[handle];
      if (entry.endsAt === null || entry.totalMs === null) continue;
      var left = (entry.endsAt - atMs) / entry.totalMs;
      if (left < 0) left = 0;
      if (left > 1) left = 1;
      entry.bar.style.width = (left * 100) + "%";
      if (left > 0) running = true;
    }
    if (running) window.requestAnimationFrame(frame);
    else pending = false;
  }

  function pump() {
    if (pending) return;
    pending = true;
    window.requestAnimationFrame(frame);
  }

  Open77.on("notify:config", function (payload) {
    try { applyConfig(payload); } catch (error) { report("config: " + describe(error)); }
  });
  Open77.on("notify:add", function (payload) {
    try { add(payload); } catch (error) { report("add: " + describe(error)); }
  });
  Open77.on("notify:update", function (payload) {
    try { update(payload); } catch (error) { report("update: " + describe(error)); }
  });
  Open77.on("notify:remove", function (payload) {
    try {
      var handle = Number((payload || {}).handle);
      if (isFinite(handle)) drop(handle, false);
    } catch (error) { report("remove: " + describe(error)); }
  });

  /* `notify:ready` MUST be emitted whatever happened above: Lua drops every message until
     the page has reported ready, so a throw before this costs the surface every toast it is
     ever sent. */
  try { Open77.ready(); } catch (error) { report("ready: " + describe(error)); }
  Open77.emit("notify:ready", {});
})();
