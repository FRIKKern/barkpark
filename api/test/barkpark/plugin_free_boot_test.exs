defmodule Barkpark.PluginFreeBootTest do
  @moduledoc """
  Goal barkpark-G1 — regression bar for the fresh-install invariant.

  Barkpark must boot, serve Studio, and serve `/api/schemas` with no plugins
  loaded. This case stops `:barkpark`, sets `:plugins` to `[]`, restarts the
  app, and asserts a 5-tier set of invariants over the live system:

    1. The supervision tree has no `Barkpark.Plugins.OnixEdit.*` children.
    2. `GET /studio/production` returns 200 with the `"Structure"` marker.
    3. `GET /api/schemas` returns exactly the 8 seed schema names.
    4. Studio HTML contains no plugin-specific tokens
       (`OnixEdit`, `Bokbasen`, `book`).
    5. Host code under `lib/barkpark` + `lib/barkpark_web` does not
       reference `Barkpark.Plugins.OnixEdit` by name (paths under
       `plugins/onixedit/` excluded).

  Tagged `:boot_test` — excluded from the default `mix test` run. Invoke
  explicitly:

      mix test --only boot_test test/barkpark/plugin_free_boot_test.exs

  The test FAILS until tasks s2 (supervisor pluginification), s3
  (content_renderer split), and s4 (settings_live split) land. That is the
  regression bar — it is the gate that keeps the fresh-install invariant
  from drifting in future PRs.
  """

  use ExUnit.Case, async: false

  @moduletag :boot_test

  import Phoenix.ConnTest

  @endpoint BarkparkWeb.Endpoint

  @expected_seed_schemas ~w(post page author category project siteSettings navigation colors)

  setup_all do
    prev_plugins = Application.get_env(:barkpark, :plugins, :unset)

    Application.put_env(:barkpark, :plugins, [])
    Application.stop(:barkpark)
    {:ok, _} = Application.ensure_all_started(:barkpark)

    # The Repo restart wipes the previous sandbox-mode setting. Restore the
    # manual/shared chain the rest of the suite assumes, then take a
    # connection so the in-process Endpoint pipeline can read.
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

    on_exit(fn ->
      Application.stop(:barkpark)

      case prev_plugins do
        :unset -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end

      {:ok, _} = Application.ensure_all_started(:barkpark)
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    end)

    :ok
  end

  describe "fresh-install invariant" do
    test "supervision tree has no OnixEdit children" do
      children = Supervisor.which_children(Barkpark.Supervisor)

      offenders =
        children
        |> Enum.map(fn {id, _pid, _type, modules} -> {id, modules} end)
        |> Enum.filter(fn {id, modules} ->
          token_match?(id) or Enum.any?(List.wrap(modules), &token_match?/1)
        end)

      assert offenders == [],
             "supervision tree contains plugin children: #{inspect(offenders)}"
    end

    test "GET /studio/production returns 200 with Structure marker" do
      conn = build_conn() |> get("/studio/production")
      body = html_response(conn, 200)

      assert body =~ "Structure",
             "expected nav marker \"Structure\" in Studio HTML, got body of #{byte_size(body)} bytes"
    end

    test "GET /api/schemas returns exactly the 8 seed schema names" do
      conn = build_conn() |> get("/api/schemas")
      body = json_response(conn, 200)

      schema_names =
        body
        |> extract_schema_names()
        |> Enum.sort()

      expected = Enum.sort(@expected_seed_schemas)

      assert schema_names == expected,
             "expected exactly #{inspect(expected)}, got #{inspect(schema_names)}"
    end

    test "Studio HTML contains no plugin-specific tokens" do
      conn = build_conn() |> get("/studio/production")
      body = html_response(conn, 200)

      for token <- ["OnixEdit", "Bokbasen", "book"] do
        refute body =~ token,
               "Studio HTML must not contain plugin token #{inspect(token)}"
      end
    end

    test "host code in lib/ does not reference Barkpark.Plugins.OnixEdit by name" do
      api_root = File.cwd!()
      paths = ["lib/barkpark", "lib/barkpark_web"]

      {output, _exit_code} =
        System.cmd(
          "grep",
          ["-r", "-l", "Barkpark.Plugins.OnixEdit" | paths],
          cd: api_root,
          stderr_to_stdout: true
        )

      offenders =
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&plugin_internal_path?/1)

      assert offenders == [],
             "host code references Barkpark.Plugins.OnixEdit: #{inspect(offenders)}"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # The legacy `/api/schemas` endpoint (`LegacyController.schemas/2`)
  # returns a bare JSON array of `%{"name" => ...}` maps. The newer
  # `/v1/schemas/:dataset` returns an envelope `%{"schemas" => [...]}`.
  # Accept both shapes so a future endpoint flip doesn't silently
  # break the regression bar.
  defp extract_schema_names(body) when is_list(body) do
    Enum.map(body, fn
      %{"name" => name} -> name
      other -> raise "unexpected schema entry shape: #{inspect(other)}"
    end)
  end

  defp extract_schema_names(%{"schemas" => list}) when is_list(list) do
    Enum.map(list, fn
      %{"name" => name} -> name
      other -> raise "unexpected schema entry shape: #{inspect(other)}"
    end)
  end

  defp extract_schema_names(other) do
    raise "unexpected /api/schemas response shape: #{inspect(other)}"
  end

  defp token_match?(term) do
    s = term |> inspect() |> to_string()
    String.contains?(s, "OnixEdit") or String.contains?(s, "Bokbasen")
  end

  # Files inside the plugin's own directory are allowed to mention
  # `Barkpark.Plugins.OnixEdit` — the violation is host code (anything
  # OUTSIDE that subtree) reaching for the plugin module by name.
  defp plugin_internal_path?(path) do
    String.contains?(path, "plugins/onixedit") or String.contains?(path, "Plugins/OnixEdit")
  end
end
