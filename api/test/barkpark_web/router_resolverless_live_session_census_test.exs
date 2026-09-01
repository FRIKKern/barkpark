defmodule BarkparkWeb.RouterResolverlessLiveSessionCensusTest do
  @moduledoc """
  task-e9386e19bd7bb376, acceptance 1 — the resolver-less flat live_sessions are
  ENUMERATED FROM THE ROUTER, not from a brief.

  `StudioChrome.on_mount(:default)` is the single producer of `:current_workspace`
  for every live_session that carries no workspace resolver of its own. That is
  what made the Default-pinning defect ONE defect across SIX mounts rather than
  six separate ones — and it is what makes a new resolver-less live_session
  silently inherit the same obligation the day someone adds it.

  A prose census goes stale the first time the router moves; the row's brief
  named two of six and asked for the rest to be counted at build time, precisely
  because a stale count is the failure mode. So this file COMPUTES the set from
  `router.ex` and pins it. If it reds, nobody has broken anything yet — a
  live_session was added, moved or re-wired, and the person who did it has to
  decide, deliberately, which column it belongs in:

    * gained a resolver (`{LiveScope, :resolve}` / `{PluginScopeSession, :scope}`)
      → move it out of @resolver_less;
    * genuinely resolver-less → add it to @resolver_less AND satisfy yourself
      that `StudioChrome.default_scope_fallback/1`'s authority check is the
      right posture for the surfaces it mounts (it pins the seeded Default ONLY
      for a principal `Tenancy.Auth.authorize/3` actually authorizes there, and
      leaves `:current_workspace` nil otherwise);
    * carries no `StudioChrome` hook at all (like `:finder`) → it never reaches
      the fallback and belongs in neither list.

  The parse is deliberately dumb — a literal scan of the declaration's option
  list — because the thing being protected is a HUMAN decision, and a clever
  parser that silently reclassifies is worse than a blunt one that reds.
  """

  use ExUnit.Case, async: true

  @router_path Path.expand("../../lib/barkpark_web/router.ex", __DIR__)

  # THE SIX, computed from router.ex on 2026-09-01 and pinned here.
  #
  #   :admin_studio                  /studio/{org-admin,styleguide,tmux,chat[,/:session_id]}
  #   :admin_swatch                  /studio/styleguide/swatch
  #   :plugin_admin                  every plugin `auth: :admin` route (Tickets InboxLive)
  #   :plugin_public                 every plugin `auth: :public` route
  #   :plugin_ops                    every plugin `auth: :ops` route
  #   :scoped_admin_studio_dataset   /w/:ws/p/:proj/d/:dataset/studio/_plugins[…]
  #
  # The last one is the surprise the brief did not name: its URL carries
  # `/w/:ws/p/:proj` (so `scope_prefix` is workspace-truthful) but its on_mount
  # list has NO resolver, so its `:current_workspace` comes from the fallback
  # exactly like the four genuinely flat ones. It is in scope for the fix by
  # construction — the fix is in the shared producer — and it is listed here so
  # the next reader does not have to rediscover it.
  @resolver_less ~w(
    admin_studio
    admin_swatch
    plugin_admin
    plugin_public
    plugin_ops
    scoped_admin_studio_dataset
  )a

  # Sessions that DO carry a resolver ahead of StudioChrome, so the fallback
  # no-ops on its truthy-assign guard. Pinned for the same reason: a resolver
  # QUIETLY REMOVED from one of these would move it into the resolver-less set,
  # and only a two-sided census notices that direction of drift.
  @resolved ~w(
    scoped_plugin_admin
    scoped_admin_studio
    scoped_plugin_public
    scoped_plugin_ops
    scoped_studio
  )a

  test "the router file the census reads actually exists" do
    # Assert the subject exists: a moved router would make every set below
    # empty, and `MapSet.new([]) == MapSet.new([])` is a green that proves
    # nothing.
    assert File.exists?(@router_path)
    assert length(declarations()) >= 10
  end

  test "every StudioChrome live_session without a resolver is one of the known six" do
    computed = MapSet.new(classify(:resolver_less))

    assert computed == MapSet.new(@resolver_less), """
    The set of live_sessions that mount `{StudioChrome, :default}` with NO
    workspace resolver has changed.

      computed: #{inspect(Enum.sort(computed))}
      pinned:   #{inspect(Enum.sort(@resolver_less))}

    Each such session reaches `StudioChrome.default_scope_fallback/1`, the
    single producer of `:current_workspace` for it. Read that function's
    comment (task-e9386e19bd7bb376) and then update @resolver_less in this
    file on purpose.
    """
  end

  test "every StudioChrome live_session that DOES carry a resolver is one of the known five" do
    computed = MapSet.new(classify(:resolved))

    assert computed == MapSet.new(@resolved), """
    The set of live_sessions that mount `{StudioChrome, :default}` BEHIND a
    workspace resolver has changed.

      computed: #{inspect(Enum.sort(computed))}
      pinned:   #{inspect(Enum.sort(@resolved))}

    If a resolver was removed, the session just joined the resolver-less set
    and inherits the Default-fallback posture — decide that deliberately.
    """
  end

  test "the two sets are disjoint and neither is empty" do
    # Guards the classifier itself: a predicate bug that answered `true` to both
    # questions, or `false` to both, would otherwise be invisible.
    resolver_less = MapSet.new(classify(:resolver_less))
    resolved = MapSet.new(classify(:resolved))

    refute Enum.empty?(resolver_less)
    refute Enum.empty?(resolved)
    assert MapSet.disjoint?(resolver_less, resolved)
  end

  # ── The census ──────────────────────────────────────────────────────────────

  defp classify(which) do
    for {name, opts} <- declarations(),
        String.contains?(opts, "{BarkparkWeb.StudioChrome, :default}"),
        resolver?(opts) == (which == :resolved),
        do: name
  end

  defp resolver?(opts) do
    String.contains?(opts, "{BarkparkWeb.LiveScope, :resolve}") or
      String.contains?(opts, "{BarkparkWeb.PluginScopeSession, :scope}")
  end

  # Every `live_session :name, …` declaration paired with the raw text of its
  # option list (everything up to the block-opening `do`).
  defp declarations do
    source = File.read!(@router_path)

    ~r/live_session\s+:([a-z_]+)((?:.|\n)*?)\sdo\n/
    |> Regex.scan(source)
    |> Enum.map(fn [_all, name, opts] -> {String.to_atom(name), opts} end)
  end
end
