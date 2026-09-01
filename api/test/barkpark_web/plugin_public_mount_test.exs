defmodule BarkparkWeb.PluginPublicMountTest do
  @moduledoc """
  snav-w1-gating-determinism, Hole 2 (admin axis).

  The `:plugin_public` / `:scoped_plugin_public` live_sessions used to mount
  `{StudioChrome, :default}` with NO LiveAuth hook, so `api_token` /
  `current_user` were never assigned, `shares_admin?` computed `false`, and the
  admin-gated Studio chrome (Style / tmux / chat tabs, Share button) silently
  vanished for an admin on any plugin-public studio-layout page — a nav element
  that appears elsewhere but disappears there.

  The fix threads `{BarkparkWeb.LiveAuth, :fetch_api_token}` BEFORE StudioChrome
  in both on_mount lists. `:fetch_api_token` is non-gating: it assigns the token
  when a session carries one and passes an anonymous visitor through WITHOUT a
  redirect. This test replays that exact on_mount composition (the router wires
  the hooks; ExUnit invokes them the same way LiveView does at mount) and pins
  both halves: an admin session now renders admin chrome, and an anonymous
  visitor still mounts.

  ## arpss-w10 — the admin session must hold a SEAT, not just a permission

  `shares_admin?` is now `BarkparkWeb.Studio.Caps.admin?/1`: workspace-scoped
  seat authority on the MOUNTED workspace (`role_permits?(membership_role,
  ws_id, :admin)`), for BOTH principal kinds. On these flat / plugin-public
  routes no resolver runs, so `StudioChrome.default_scope_fallback/1` pins the
  seeded Default workspace — and that is the workspace the seat is read in.

  The admin case below therefore now gives its token an admin membership THERE.
  It is not test-fitting: the previous shape (an `admin`-permissioned token with
  ZERO membership rows anywhere) was defect (2) of
  `arpss-w10-bl-studiochrome-admin-default-workspace-scoping` — a phantom admin
  affordance handed to a non-member, under a workspace LABEL they have no
  relationship with. The third test pins that exact principal at `false` and is
  the regression guard for it.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias BarkparkWeb.{LiveAuth, StudioChrome}

  # Replays the `:plugin_public` on_mount list
  # `[{LiveAuth, :fetch_api_token}, {StudioChrome, :default}]` — the same order
  # `:scoped_plugin_public` uses (its extra PluginScopeSession hook only assigns
  # tenancy scope and does not touch the admin axis).
  defp mount_plugin_public(session) do
    # A mount-ready socket: LiveView initialises `private.lifecycle` before it
    # runs on_mount hooks, and StudioChrome.on_mount attaches a handle_event
    # hook, so a bare `%Socket{}` (no lifecycle) would KeyError. It must also
    # look ROUTER-mounted (`router:` set) — every real :plugin_public view is
    # mounted via live/3, and StudioChrome's :handle_params hook (the
    # current_path producer) refuses to attach to a non-router socket.
    socket = %Phoenix.LiveView.Socket{
      router: BarkparkWeb.Router,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:cont, s1} = LiveAuth.on_mount(:fetch_api_token, %{}, session, socket)
    {:cont, s2} = StudioChrome.on_mount(:default, %{"dataset" => "production"}, session, s1)
    s2
  end

  describe "plugin_public on_mount chain (fetch_api_token → StudioChrome)" do
    test "an admin session renders admin-gated chrome (shares_admin? true)" do
      {_default_ws, _proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
      raw = "plugin-public-admin-#{System.unique_integer([:positive])}"

      # `create_token/5` writes the token's home membership in the resolved
      # (Default) workspace, with the role its permissions imply — so this
      # admin token holds an admin SEAT there without the test saying so. That
      # is why arpss-w10 leaves this case green: it was always a real admin of
      # the workspace the flat chrome labels it with.
      {:ok, _} =
        Auth.create_token(raw, "plugin public admin", "production", ["read", "write", "admin"])

      mounted = mount_plugin_public(%{"api_token" => raw})

      # fetch_api_token verified + assigned the token…
      assert %Barkpark.Auth.ApiToken{} = mounted.assigns.api_token
      assert Auth.has_permission?(mounted.assigns.api_token, "admin")
      # …so StudioChrome computed admin? true → admin chrome renders.
      assert mounted.assigns.shares_admin? == true
    end

    test "arpss-w10: an admin-permissioned token with NO membership anywhere gets NO admin chrome" do
      {_default_ws, _proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
      raw = "plugin-public-seatless-#{System.unique_integer([:positive])}"

      # Inserted DIRECTLY, bypassing `Auth.create_token/5` — that helper would
      # have written a home membership and made the token a real admin. This is
      # the seatless principal the wave-10 mount proof found: `admin` in
      # `permissions[]`, zero membership rows anywhere.
      {:ok, _token} =
        %Barkpark.Auth.ApiToken{}
        |> Barkpark.Auth.ApiToken.changeset(%{
          token_hash: Barkpark.Auth.ApiToken.hash_token(raw),
          label: "seatless admin",
          dataset: "production",
          permissions: ["read", "write", "admin"]
        })
        |> Barkpark.Repo.insert()

      mounted = mount_plugin_public(%{"api_token" => raw})

      # SUPERSEDED (task-e9386e19bd7bb376). This assertion used to read
      # `mounted.assigns.current_workspace.slug == "default"`, over a comment
      # calling that label "its own (smaller) open lie, tracked with the parent
      # task". That lie is now CLOSED: `Tenancy.Auth.authorize/3` is
      # `member?(token, ws) and permits?(token, action)` with no global bypass,
      # so this seatless token is authorized in NO workspace — Default included
      # — and `StudioChrome.default_scope_fallback/1` no longer hands it one.
      #
      # `:plugin_public` is one of the six resolver-less live_sessions that
      # share that single producer, so it inherits the narrowing without a line
      # of its own. The arpss-w10 point this test exists to pin is UNCHANGED and
      # is asserted below: the seat-scoped affordance stays false, the
      # host-level oracle stays true.
      assert Auth.has_permission?(mounted.assigns.api_token, "admin")
      assert mounted.assigns.current_workspace == nil

      # But it holds no seat there, so the workspace-scoped affordance is gone.
      # Pre-fix this was `true` — the phantom Share button for a non-member.
      assert mounted.assigns.shares_admin? == false

      # The HOST-level oracle is deliberately NOT narrowed with it: the
      # self-update banner still answers to an admin api_token. The split is the
      # fix, not a uniform tightening.
      assert mounted.assigns.instance_admin? == true

      # …and Caps did NOT become ATTACHED to this route as a side effect of the
      # chrome calling it. `Caps.admin?/1` is a pure predicate over assigns the
      # chrome already holds; `Caps.attach/1` (the deny-gate) and `derive/1`'s
      # `:caps` assign stay exclusive to `StudioLive.mount`. This is the premise
      # `arpss-w10-caps-mount-reachability-ratchet` pins from the mount side —
      # asserted here so the fix cannot quietly invalidate it.
      assert mounted.assigns[:caps] == nil
      assert mounted.assigns[:caps_gate?] == nil
    end

    test "an anonymous visitor still mounts — no redirect, chrome present but not admin" do
      # No api_token in the session: fetch_api_token must {:cont, …} (never
      # halt/redirect), StudioChrome must still mount with admin chrome off.
      mounted = mount_plugin_public(%{})

      assert mounted.assigns.api_token == nil
      assert mounted.assigns.shares_admin? == false
    end
  end
end
