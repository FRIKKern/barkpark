defmodule BarkparkWeb.Icons do
  @moduledoc """
  Inline SVG icons. No JS dependency.

  ## Unknown names

  `icon/1` used to answer an unknown name with the "file" glyph, silently — an
  accidental `Map.get/3` default (200cd5750, 2026-04-12), never a designed UX.
  It cost real pictures: `arrow-left` was missing while three call sites asked
  for it by name, so back controls painted a DOCUMENT for months, and
  `alert-triangle` was missing while `chat_readiness_card/1` asked for it, so
  every AI-provider-not-ready warning in Studio chat painted a document too.
  Nothing red, nothing logged, nothing a reviewer reading the call site could
  see.

  The policy is now explicit, and it is `@unknown_icon_policy`:

    * `:test` → **raise**. A developer-authored literal that names a glyph we do
      not have is a bug, and the enumeration tripwire in
      `BarkparkWeb.IconsTripwireTest` turns the whole of `lib/` into one
      assertion of that.

      The policy governs BOTH failure shapes — an unknown BINARY name, and a
      NON-BINARY name (`nil`, an atom, a number). See the fail-safe below.
    * `:dev` and `:prod` → `Logger.warning/1` plus the "file" fallback. A page
      is NEVER crashed over a cosmetic glyph. `:dev` is deliberately grouped
      with `:prod` rather than with `:test` (which the brief's recommendation
      would have done via `Mix.env() != :prod`) because `tab_icon/1`
      (`studio_components/editor.ex:808`) passes a **tenant/schema-supplied**
      icon string through verbatim: raising in `:dev` would let any workspace
      whose schema carries an unmapped emoji take down the local editor. The
      gating idiom follows `live_auth.ex:163`, but resolved at COMPILE time so
      nothing depends on `Mix` being loaded at runtime.

  ## The non-binary fail-safe (spd-w18-nil-icon-500)

  `resolve_paths/2` used to be a SINGLE `when is_binary(name)` clause, so a
  non-binary name did not fall back — it raised `FunctionClauseError`, in every
  environment, `:warn` policy included. The moduledoc's own promise ("a page is
  NEVER crashed over a cosmetic glyph") was therefore FALSE for `nil`, and the
  authenticated Studio proved it: `/studio/rest` and `/studio/plugins` both
  returned HTTP 500 (`resolve_paths(nil, :warn)` ← `icon/1` ←
  `studio_live_shell/1`) while `/studio` returned 200, and clicking the …Rest
  desk row was simply DEAD because `Scope.select` only `push_patch`es and cannot
  distinguish a crashing destination from a no-op.

  There is now a non-binary clause, and it is POLICY-AWARE — the same fork
  `unknown_icon/3` already carries, so the module holds ONE policy concept
  rather than one policy-aware clause and one policy-blind one:

    * `:warn` (`:dev` and `:prod`) → `Logger.warning/1` plus the "file" glyph.
      This is the arm that PRODUCTION runs, and it is what makes the moduledoc's
      promise true: a nil icon never crashes a page again. All three
      spd-w18-nil-icon-500 destinations are served by this arm.
    * `:raise` (`:test`) → `ArgumentError`. A non-binary name reaching `icon/1`
      means some call site forwarded unbounded data without `drawable_name/2`,
      and `:test` is exactly where we want to hear about that. Falling back
      under `:raise` too would have bought nothing at runtime (prod is `:warn`)
      while spending the only tripwire this shape can have — the literal
      scanner structurally cannot see `name={item.icon}`.
    * The literal contract keeps every tooth it had: an unknown *binary* name
      still raises under `:raise`, and `IconsTripwireTest` still enumerates
      every literal in `lib/`.

  Bound, stated honestly: no CURRENT dynamic `name={…}` site can reach the
  `:raise` arm — each routes through `drawable_name/2`, or `|| "file"`, or sits
  inside `if item.icon`. It is a REGRESSION TRIPWIRE for the next unguarded
  site (and for a TRUTHY non-binary, where `|| "file"` does not save you:
  `:folder || "file"` is `:folder`), not a fix for anything live.

  The tripwire is a literal scanner and structurally CANNOT see
  `name={item.icon}`. The guard for that shape is `drawable_name/2` at the call
  site plus a test that RENDERS — `BarkparkWeb.Studio.NilIconNeverCrashesTest`.

  `known_icon?/1` is the public predicate behind all of this — it answers the
  same question `icon/1` asks (emoji alias resolved, then map membership), so a
  caller holding an unbounded string can check before rendering, and
  `drawable_name/2` is the one-liner that turns it into a name you can pass on.
  """

  use Phoenix.Component

  require Logger

  @icons %{
    "file-text" =>
      ~s(<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>),
    "file" =>
      ~s(<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>),
    "book" => ~s(<path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1 0-5H20"/>),
    "user" =>
      ~s(<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>),
    "tag" =>
      ~s(<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>),
    "briefcase" =>
      ~s(<path d="M16 20V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/><rect width="20" height="14" x="2" y="6" rx="2"/>),
    "settings" =>
      ~s(<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>),
    "compass" =>
      ~s(<circle cx="12" cy="12" r="10"/><polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"/>),
    "palette" =>
      ~s(<circle cx="13.5" cy="6.5" r=".5" fill="currentColor"/><circle cx="17.5" cy="10.5" r=".5" fill="currentColor"/><circle cx="8.5" cy="7.5" r=".5" fill="currentColor"/><circle cx="6.5" cy="12" r=".5" fill="currentColor"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z"/>),
    "image" =>
      ~s(<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>),
    "log-out" =>
      ~s(<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>),
    "layout-list" =>
      ~s(<rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/><path d="M14 4h7"/><path d="M14 9h7"/><path d="M14 15h7"/><path d="M14 20h7"/>),
    "chevron-right" => ~s(<path d="m9 18 6-6-6-6"/>),
    "chevron-down" => ~s(<path d="m6 9 6 6 6-6"/>),
    # spd-b39. `arrow-left` was ALREADY being asked for by name in three places
    # — `layouts/studio.html.heex` (the back button), `chat_live.ex` (the
    # un-archive toggle) and now the Tier-3 inspector dismissal — and `icon/1`
    # answers an unknown name with the "file" fallback rather than raising, so
    # every one of them has been silently painting a DOCUMENT glyph on a back
    # control. Adding the entry fixes all three at once.
    "arrow-left" => ~s(<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>),
    "plus" => ~s(<path d="M5 12h14"/><path d="M12 5v14"/>),
    "folder" =>
      ~s(<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>),
    "check-circle" =>
      ~s(<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><path d="m9 11 3 3L22 4"/>),
    # spd icons-unknown-name-tripwire. `alert-triangle` was asked for by name at
    # `live/studio/chat_live.ex` in `chat_readiness_card/1` — the
    # AI-provider-not-ready warning — while absent from this map, so every
    # not-ready state in Studio chat has been painting the "file" document glyph
    # next to its warning copy since the card shipped. Lucide `triangle-alert`.
    "alert-triangle" =>
      ~s(<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>),
    "calendar" =>
      ~s(<rect width="18" height="18" x="3" y="4" rx="2" ry="2"/><line x1="16" x2="16" y1="2" y2="6"/><line x1="8" x2="8" y1="2" y2="6"/><line x1="3" x2="21" y1="10" y2="10"/>),
    "copy" =>
      ~s(<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>),
    "refresh-cw" =>
      ~s(<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>),
    # Editor-header action icons (task barkpark-jl4x). Inline SVG paths
    # copied from Lucide v0.460 so we keep zero JS dependencies.
    "message-circle" => ~s(<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>),
    "send" =>
      ~s(<path d="M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"/><path d="m21.854 2.147-10.94 10.939"/>),
    "archive" =>
      ~s(<rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>),
    "trash-2" =>
      ~s(<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><line x1="10" x2="10" y1="11" y2="17"/><line x1="14" x2="14" y1="11" y2="17"/>),
    "history" =>
      ~s(<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>),
    # Asked for by name at `studio_live/doc_actions.ex:183` — the "Revert to
    # published" action — while absent here, so the revert button has been
    # painting the "file" document glyph. Lucide `rotate-ccw`: the `history`
    # arc without the clock hands.
    "rotate-ccw" =>
      ~s(<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>),
    "code" => ~s(<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>),
    "terminal" => ~s(<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>),
    "external-link" =>
      ~s(<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>),
    "git-compare" =>
      ~s(<circle cx="5" cy="6" r="3"/><path d="M12 6h5a2 2 0 0 1 2 2v7"/><path d="m15 9-3-3 3-3"/><circle cx="19" cy="18" r="3"/><path d="M12 18H7a2 2 0 0 1-2-2V9"/><path d="m9 15 3 3-3 3"/>),
    # Asked for by name at `studio_live/doc_actions.ex:230` — "View blast
    # radius", the only affordance that reaches the Canvas2D graph pane —
    # while absent here. Lucide `git-fork`.
    "git-fork" =>
      ~s(<circle cx="12" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><circle cx="18" cy="6" r="3"/><path d="M18 9v2c0 .6-.4 1-1 1H7c-.6 0-1-.4-1-1V9"/><path d="M12 12v3"/>),
    # Both asked for by name at `barkpark/tasks/schema.ex:67,69` — the task
    # schema's "Brief" and "Close" tab groups — while absent here, so both
    # tabs have been painting the "file" document glyph.
    "clipboard-list" =>
      ~s(<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>),
    "flag" =>
      ~s(<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" x2="4" y1="22" y2="15"/>),
    # The glyph every Sheets schema names for its grid tab. Schema-supplied, so
    # no static scan of lib/ could ever have found it — it was traced from the
    # tab bar painting a document on the Sheets desk. Lucide `grid-3x3`.
    "grid" =>
      ~s(<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/><path d="M9 3v18"/><path d="M15 3v18"/>),
    "panel-right-open" =>
      ~s(<rect width="18" height="18" x="3" y="3" rx="2"/><line x1="15" x2="15" y1="3" y2="21"/><path d="m10 15-3-3 3-3"/>),
    "download" =>
      ~s(<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>),
    "cloud-upload" =>
      ~s(<path d="M12 13v8"/><path d="M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242"/><path d="m8 17 4-4 4 4"/>),
    # Editor group-tab icons (task barkpark-sfzn). Lucide v0.460 paths.
    "home" =>
      ~s(<path d="M3 9.5 12 2l9 7.5"/><path d="M5 9v11a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V9"/>),
    "align-left" => ~s(<path d="M15 12H3"/><path d="M17 18H3"/><path d="M21 6H3"/>),
    "users" =>
      ~s(<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>),
    "megaphone" => ~s(<path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>),
    "building" =>
      ~s(<rect width="16" height="20" x="4" y="2" rx="2" ry="2"/><path d="M9 22v-4h6v4"/><path d="M8 6h.01"/><path d="M16 6h.01"/><path d="M12 6h.01"/><path d="M12 10h.01"/><path d="M12 14h.01"/><path d="M16 10h.01"/><path d="M16 14h.01"/><path d="M8 10h.01"/><path d="M8 14h.01"/>),
    "package" =>
      ~s(<path d="m7.5 4.27 9 5.15"/><path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="M3.3 7 12 12l8.7-5"/><path d="M12 22V12"/>),
    "activity" =>
      ~s(<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.5.5 0 0 1-.96 0L9.24 2.18a.5.5 0 0 0-.96 0l-2.35 8.36A2 2 0 0 1 4 12H2"/>),
    "circle" => ~s(<circle cx="12" cy="12" r="10"/>),
    # Theme-toggle icons (task barkpark-hdq9). Lucide v0.460 paths; zero JS dep.
    "sun" =>
      ~s(<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>),
    "moon" => ~s(<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>),
    # Paper block-editor View/Edit toggle icons (convergence/studio-paper-editor).
    # Lucide v0.460 paths; zero JS dependency.
    "eye" =>
      ~s(<path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>),
    "pencil" =>
      ~s(<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>),
    # Scoped-sharing affordance (Studio Shares panel + Share buttons). Lucide
    # v0.460 share-2 path; zero JS dependency.
    "share-2" =>
      ~s(<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/><line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>),
    # Desk-tree + top-bar type icons (task sup-w1-icon-authority). Every document
    # type resolves to a distinct glyph; plugin desk links (columns/zap/github/
    # clock) and the sibling top-bar slice (folder-tree/zap/palette/terminal/
    # messages-square) consume these names. Lucide v0.460 paths; zero JS dep.
    "newspaper" =>
      ~s(<path d="M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-2 2Zm0 0a2 2 0 0 1-2-2v-9c0-1.1.9-2 2-2h2"/><path d="M18 14h-8"/><path d="M15 18h-5"/><path d="M10 6h8v4h-8V6Z"/>),
    "table" =>
      ~s(<path d="M12 3v18"/><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/>),
    "ticket" =>
      ~s(<path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"/><path d="M13 5v2"/><path d="M13 17v2"/><path d="M13 11v2"/>),
    "puzzle" =>
      ~s(<path d="M15.39 4.39a1 1 0 0 0 1.68-.474 2.5 2.5 0 1 1 3.014 3.015 1 1 0 0 0-.474 1.68l1.683 1.682a2.414 2.414 0 0 1 0 3.414L19.61 15.39a1 1 0 0 1-1.68-.474 2.5 2.5 0 1 0-3.014 3.015 1 1 0 0 1 .474 1.68l-1.683 1.682a2.414 2.414 0 0 1-3.414 0L8.61 19.61a1 1 0 0 0-1.68.474 2.5 2.5 0 1 1-3.014-3.015 1 1 0 0 0 .474-1.68l-1.683-1.682a2.414 2.414 0 0 1 0-3.414L4.39 8.61a1 1 0 0 1 1.68.474 2.5 2.5 0 1 0 3.014-3.015 1 1 0 0 1-.474-1.68l1.683-1.682a2.414 2.414 0 0 1 3.414 0z"/>),
    "folder-tree" =>
      ~s(<path d="M20 10a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1h-2.5a1 1 0 0 1-.8-.4l-.9-1.2A1 1 0 0 0 15 3h-2a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1Z"/><path d="M20 21a1 1 0 0 0 1-1v-3a1 1 0 0 0-1-1h-2.9a1 1 0 0 1-.88-.55l-.42-.85a1 1 0 0 0-.92-.6H13a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1Z"/><path d="M3 5a2 2 0 0 0 2 2h3"/><path d="M3 3v13a2 2 0 0 0 2 2h3"/>),
    "columns" => ~s(<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M12 3v18"/>),
    "kanban" => ~s(<path d="M6 5v11"/><path d="M12 5v6"/><path d="M18 5v14"/>),
    "check-square" =>
      ~s(<path d="M21 10.5V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h12.5"/><path d="m9 11 3 3L22 4"/>),
    "zap" =>
      ~s(<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>),
    "github" =>
      ~s(<path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"/><path d="M9 18c-4.51 2-5-2-7-2"/>),
    "clock" => ~s(<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>),
    "sticky-note" =>
      ~s(<path d="M15.5 3H5a2 2 0 0 0-2 2v14c0 1.1.9 2 2 2h9.5L21 15.5V5a2 2 0 0 0-2-2z"/><path d="M15 21v-5a1 1 0 0 1 1-1h5"/>),
    "messages-square" =>
      ~s(<path d="M16 10a2 2 0 0 1-2 2H6l-4 4V4c0-1.1.9-2 2-2h10a2 2 0 0 1 2 2z"/><path d="M20 9a2 2 0 0 1 2 2v11l-4-4h-6a2 2 0 0 1-2-2v-1"/>),
    # Field-group tab glyphs shipped by the media plugin's schemas
    # (media_asset "rights", media_collection "sharing"). Both were named in
    # priv/ and drawn nowhere — see the priv/ scan in icons_tripwire_test.exs.
    "shield" =>
      ~s(<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>),
    "link" =>
      ~s(<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>)
  }

  @emoji_map %{
    "📄" => "file-text",
    "📑" => "sticky-note",
    "👤" => "user",
    "🏷" => "tag",
    "💼" => "briefcase",
    "⚙" => "settings",
    "🧭" => "compass",
    "🎨" => "palette",
    "📁" => "folder",
    "📂" => "folder",
    "🖼" => "image",
    "✅" => "check-square",
    "📰" => "newspaper",
    "📊" => "table",
    "🎫" => "ticket",
    "🧩" => "puzzle",
    "🗂" => "folder-tree"
  }

  # Resolved at COMPILE time so no runtime `Mix` dependency exists (a release
  # has no Mix). See the moduledoc for why `:dev` sits with `:prod`, not `:test`.
  @unknown_icon_policy if Mix.env() == :test, do: :raise, else: :warn

  def icon_name(emoji), do: Map.get(@emoji_map, emoji, "file")

  @doc """
  Every glyph name this module can actually draw, sorted.

  Emoji aliases are NOT included — pass them through `known_icon?/1`, which
  resolves an alias first.
  """
  @spec icon_names() :: [String.t()]
  def icon_names, do: @icons |> Map.keys() |> Enum.sort()

  @doc """
  True when `name` resolves to a real glyph — i.e. when `icon/1` would draw the
  picture the call site asked for rather than the "file" fallback.

  Asks exactly what `icon/1` asks: resolve an emoji alias, then check map
  membership. This is the predicate the `lib/`-wide enumeration tripwire runs
  over every `<.icon name="…"/>` literal in the tree, and it is the guard a
  caller holding an unbounded string (a tenant-supplied schema icon, say)
  should use before rendering.
  """
  @spec known_icon?(term()) :: boolean()
  def known_icon?(name) when is_binary(name),
    do: Map.has_key?(@icons, Map.get(@emoji_map, name, name))

  def known_icon?(_), do: false

  @doc """
  The name to actually render for an UNBOUNDED icon name — schema data, plugin
  data, a `Barkpark.Structure.Node`'s `:icon` — collapsing BOTH failure shapes
  (non-binary, and an unknown string) to `fallback` at the CALL SITE, before
  `icon/1` is ever asked.

  This is the guard for the shape the `lib/`-wide literal tripwire structurally
  cannot see: `name={item.icon}`. `resolve_paths/2`'s fail-safe clause keeps such
  a call site from CRASHING in dev/prod (and reds it in `:test`, so it gets
  guarded); `drawable_name/2` is the guard, and it also keeps the call site from
  silently returning the wrong picture, by letting it choose a glyph that means
  something there (`"folder"` for a section header, `"circle"` for a tab).
  You want both — see the moduledoc.

      iex> BarkparkWeb.Icons.drawable_name("folder")
      "folder"
      iex> BarkparkWeb.Icons.drawable_name(nil)
      "file"
      iex> BarkparkWeb.Icons.drawable_name("no-such-glyph", "circle")
      "circle"
  """
  @spec drawable_name(term(), String.t()) :: String.t()
  def drawable_name(name, fallback \\ "file") do
    if known_icon?(name), do: name, else: fallback
  end

  @doc false
  # The whole resolution, with the unknown-name policy passed in rather than
  # baked in, so BOTH branches are provable from a single `:test` run — the
  # `:warn` (dev/prod) path must be shown to still fall back and NOT raise.
  @spec resolve_paths(term(), :raise | :warn) :: String.t()
  def resolve_paths(name, policy \\ @unknown_icon_policy)

  def resolve_paths(name, policy) when is_binary(name) do
    svg_name = Map.get(@emoji_map, name, name)

    case Map.fetch(@icons, svg_name) do
      {:ok, paths} -> paths
      :error -> unknown_icon(name, svg_name, policy)
    end
  end

  # THE FAIL-SAFE (spd-w18-nil-icon-500). A non-binary name is runtime DATA that
  # reached an interpolated `name={item.icon}` — never a developer-authored
  # literal. It is POLICY-AWARE, mirroring `unknown_icon/3` below: warn and paint
  # the "file" glyph under `:warn` (dev/prod), so a nil never 500s a page again;
  # raise under `:raise` (test), because an unguarded dynamic call site is a bug
  # and the literal tripwire structurally cannot see `name={item.icon}`.
  def resolve_paths(name, policy), do: non_binary_icon(name, policy)

  defp non_binary_icon(name, :raise) do
    raise ArgumentError, """
    non-binary icon name #{inspect(name)}.

    `<.icon name={…} />` was handed runtime DATA (a schema's `:icon`, a
    `Barkpark.Structure.Node`'s `:icon`, a plugin's) that is not a string, so it
    would have painted the "file" document glyph instead of the picture the row
    asked for. Guard the call site:

        <.icon name={BarkparkWeb.Icons.drawable_name(item.icon, "folder")} />

    so the fallback glyph is chosen where it means something. Note `|| "file"`
    does NOT cover this shape when the value is truthy — `:folder || "file"` is
    `:folder`.

    Outside :test this warns and falls back rather than raising — a cosmetic
    glyph never crashes a page.
    """
  end

  defp non_binary_icon(name, _policy) do
    Logger.warning(
      "BarkparkWeb.Icons: non-binary icon name #{inspect(name)} — falling back to the " <>
        ~s("file" glyph. Guard the call site with `drawable_name/2` to choose a ) <>
        "meaningful glyph instead."
    )

    Map.get(@icons, "file", "")
  end

  defp unknown_icon(name, svg_name, :raise) do
    raise ArgumentError, """
    unknown icon name #{inspect(name)}#{if svg_name != name, do: " (emoji alias for #{inspect(svg_name)})", else: ""}.

    BarkparkWeb.Icons has no such glyph, so `<.icon name=#{inspect(name)} />` would
    have painted the "file" document glyph instead of the picture it asked for.
    Add the path to @icons in lib/barkpark_web/components/icons.ex, or use one of
    the #{length(icon_names())} names it already carries.

    Outside :test this warns and falls back rather than raising — a cosmetic
    glyph never crashes a page.
    """
  end

  defp unknown_icon(name, _svg_name, :warn) do
    Logger.warning(
      "BarkparkWeb.Icons: unknown icon name #{inspect(name)} — falling back to the \"file\" glyph"
    )

    Map.get(@icons, "file", "")
  end

  attr :name, :string, required: true
  attr :size, :integer, default: 16

  def icon(assigns) do
    paths = resolve_paths(assigns.name)
    assigns = assign(assigns, paths: paths)

    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" width={@size} height={@size} viewBox="0 0 24 24"
      fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
      style="display:inline-block;vertical-align:middle;flex-shrink:0;">
      <%= Phoenix.HTML.raw(@paths) %>
    </svg>
    """
  end
end
