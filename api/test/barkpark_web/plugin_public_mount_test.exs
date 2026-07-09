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
    # hook, so a bare `%Socket{}` (no lifecycle) would KeyError.
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:cont, s1} = LiveAuth.on_mount(:fetch_api_token, %{}, session, socket)
    {:cont, s2} = StudioChrome.on_mount(:default, %{"dataset" => "production"}, session, s1)
    s2
  end

  describe "plugin_public on_mount chain (fetch_api_token → StudioChrome)" do
    test "an admin session renders admin-gated chrome (shares_admin? true)" do
      raw = "plugin-public-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "plugin public admin", "production", ["read", "write", "admin"])

      mounted = mount_plugin_public(%{"api_token" => raw})

      # fetch_api_token verified + assigned the token…
      assert %Barkpark.Auth.ApiToken{} = mounted.assigns.api_token
      assert Auth.has_permission?(mounted.assigns.api_token, "admin")
      # …so StudioChrome computed admin? true → admin chrome renders.
      assert mounted.assigns.shares_admin? == true
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
