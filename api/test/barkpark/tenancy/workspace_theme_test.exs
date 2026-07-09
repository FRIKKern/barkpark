defmodule Barkpark.Tenancy.WorkspaceThemeTest do
  @moduledoc """
  Workspace theme identity (ts-w4e): the persisted, server-resolved theme
  switch — orthogonal to light/dark mode. Proves the storage + resolution +
  validation contract `workspace_theme/1` and `set_workspace_theme/2` own.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace

  defp workspace!(attrs \\ %{}) do
    slug = "ws-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(Map.merge(%{slug: slug, name: "T #{slug}"}, attrs))
    ws
  end

  describe "workspace_theme/1" do
    test "a fresh workspace (no settings) resolves to the default theme" do
      ws = workspace!()
      assert ws.settings == %{}
      assert Tenancy.workspace_theme(ws) == Tenancy.default_theme()
      assert Tenancy.workspace_theme(ws) == "evergreen"
    end

    test "a stored KNOWN theme is returned verbatim" do
      ws = workspace!(%{settings: %{"theme" => "evergreen"}})
      assert Tenancy.workspace_theme(ws) == "evergreen"
    end

    test "an UNKNOWN stored theme degrades to the default (never trusts stale data)" do
      ws = %Workspace{settings: %{"theme" => "ferngully-9000"}}
      assert Tenancy.workspace_theme(ws) == Tenancy.default_theme()
    end

    test "a nil workspace is guarded → default theme" do
      assert Tenancy.workspace_theme(nil) == Tenancy.default_theme()
    end

    test "a workspace whose settings is nil (legacy row) → default theme" do
      assert Tenancy.workspace_theme(%Workspace{settings: nil}) == Tenancy.default_theme()
    end
  end

  describe "set_workspace_theme/2" do
    test "persists a known theme and round-trips through workspace_theme/1" do
      ws = workspace!()
      assert {:ok, updated} = Tenancy.set_workspace_theme(ws, "evergreen")
      assert updated.settings["theme"] == "evergreen"

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.workspace_theme(reloaded) == "evergreen"
    end

    test "accepts a workspace id binary" do
      ws = workspace!()
      assert {:ok, updated} = Tenancy.set_workspace_theme(ws.id, "evergreen")
      assert updated.settings["theme"] == "evergreen"
    end

    test "rejects an unknown theme without touching the row" do
      ws = workspace!()
      assert {:error, :unknown_theme} = Tenancy.set_workspace_theme(ws, "not-a-theme")
      assert Tenancy.get_workspace_by_id(ws.id).settings == %{}
    end

    test "preserves unrelated settings keys (merge, not replace)" do
      ws = workspace!(%{settings: %{"other" => "keep-me"}})
      assert {:ok, updated} = Tenancy.set_workspace_theme(ws, "evergreen")
      assert updated.settings["theme"] == "evergreen"
      assert updated.settings["other"] == "keep-me"
    end

    test "a malformed id returns :not_found without a DB write" do
      assert {:error, :not_found} = Tenancy.set_workspace_theme("not-a-uuid", "evergreen")
    end

    test "a well-formed but absent id returns :not_found" do
      assert {:error, :not_found} =
               Tenancy.set_workspace_theme(Ecto.UUID.generate(), "evergreen")
    end
  end

  describe "known_themes/0" do
    test "is a non-empty list that includes the default" do
      themes = Tenancy.known_themes()
      assert is_list(themes) and themes != []
      assert Tenancy.default_theme() in themes
    end

    test "delegates to the generated TokensGen theme list (atoms → strings)" do
      # The allowlist is no longer a hand-kept module attribute — it is the
      # generated theme set (design/emit.mjs loops design/themes/*.json → the
      # TokensGen.themes/0 atom list). Adding theme N+1 grows both in lockstep.
      generated = Enum.map(Barkpark.PortableDoc.Render.TokensGen.themes(), &Atom.to_string/1)
      assert Tenancy.known_themes() == generated
      assert "evergreen" in Tenancy.known_themes()
    end

    test "an unknown id is still rejected by set_workspace_theme/2 (function-body guard)" do
      ws = workspace!()
      refute "ferngully-9000" in Tenancy.known_themes()
      assert {:error, :unknown_theme} = Tenancy.set_workspace_theme(ws, "ferngully-9000")
      assert Tenancy.get_workspace_by_id(ws.id).settings == %{}
    end
  end
end
