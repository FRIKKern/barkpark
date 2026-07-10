defmodule BarkparkWeb.StudioComponents.EnvBannerTest do
  @moduledoc """
  Guards the staging-barkpark environment-identity strip
  (`Nav.studio_env_banner/1`). Pure component render — no Repo, no server
  boot — driven only by `Application.get_env(:barkpark, :instance_env)`,
  which each test sets with `Application.put_env` and restores on exit so
  the suite stays order-independent.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.StudioComponents.Nav

  # Set :instance_env for the duration of one test, restoring whatever was
  # there before (default nil) afterwards — never leaks to sibling tests.
  defp put_env(value) do
    prev = Application.get_env(:barkpark, :instance_env)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:barkpark, :instance_env),
        else: Application.put_env(:barkpark, :instance_env, prev)
    end)

    Application.put_env(:barkpark, :instance_env, value)
  end

  defp render, do: render_component(&Nav.studio_env_banner/1, %{})

  describe "absent states — production and dev render nothing" do
    test "nil (unset — the dev/test default) emits no markup" do
      put_env(nil)
      html = render()
      refute html =~ "bp-env-banner"
      assert String.trim(html) == ""
    end

    test "\"prod\" emits no markup" do
      put_env("prod")
      refute render() =~ "bp-env-banner"
    end

    test "\"production\" emits no markup" do
      put_env("production")
      refute render() =~ "bp-env-banner"
    end

    test "empty / whitespace-only tag emits no markup" do
      put_env("   ")
      refute render() =~ "bp-env-banner"
    end
  end

  describe "staging — the canary strip" do
    test "renders the strip with the disposable-data copy" do
      put_env("staging")
      html = render()

      assert html =~ "bp-env-banner"
      assert html =~ "STAGING — canary for Barkpark builds; data is disposable"
    end

    test "carries status role, an aria-label, and the env data attribute" do
      put_env("staging")
      html = render()

      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-label="Staging environment — data is disposable")
      assert html =~ ~s(data-env="staging")
    end

    test "themes via tokens only — no hex/hsl color literals (studio-literal-check contract)" do
      put_env("staging")
      html = render()

      assert html =~ "var(--warn)"
      assert html =~ "var(--warn-fg)"
      refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
      refute html =~ ~r/hsl\(/
    end

    test "case/whitespace-insensitive — \"  Staging \" still renders the canary copy" do
      put_env("  Staging ")
      html = render()

      assert html =~ "STAGING — canary for Barkpark builds; data is disposable"
      assert html =~ ~s(data-env="staging")
    end
  end

  describe "generic tag — any other non-empty env self-labels" do
    test "an unknown env renders a strip carrying the uppercased tag" do
      put_env("preview")
      html = render()

      assert html =~ "bp-env-banner"
      assert html =~ "PREVIEW"
      assert html =~ ~s(aria-label="PREVIEW environment")
      assert html =~ ~s(data-env="preview")
      # NOT the staging-specific copy.
      refute html =~ "canary for Barkpark builds"
    end
  end
end
