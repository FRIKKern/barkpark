defmodule Barkpark.Plugins.CapabilitiesProjectTest do
  # PURE projection tests — no app, no DB, no registry. `project/2` is a pure
  # `(manifest_map, caller_tier) -> manifest_map` function, so these run fully
  # in-process without booting Barkpark.
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Capabilities

  # A hand-built superset manifest covering every auth tier in the enum.
  defp superset do
    %{
      "manifest_version" => "1",
      "server" => %{
        "name" => "test",
        "version" => "0.0.0",
        "base_url" => "http://localhost:4000"
      },
      "auth_tier" => "admin",
      "generated_at" => "2026-06-07T12:00:00Z",
      "etag" => "W/\"seed\"",
      "nouns" => [
        %{"name" => "doc", "summary" => "Documents.", "plugin" => nil},
        %{"name" => "schema", "summary" => "Schemas.", "plugin" => nil},
        %{"name" => "webhook", "summary" => "Webhooks.", "plugin" => nil},
        %{"name" => "workspace", "summary" => "Tenancy.", "plugin" => nil},
        %{"name" => "bulldocs", "summary" => "Papers.", "plugin" => "bulldocs"}
      ],
      "commands" => [
        cmd("doc.get", "doc", "none"),
        cmd("doc.ls", "doc", "read"),
        cmd("doc.mutate", "doc", "write"),
        cmd("schema.apply", "schema", "admin"),
        cmd("webhook.create", "webhook", "write"),
        cmd("workspace.ls", "workspace", "read"),
        # workspace.create is READ-tier: POST /api/workspaces is behind
        # RequireToken only (any authenticated token may self-serve a workspace).
        cmd("workspace.create", "workspace", "read"),
        cmd("workspace.project-create", "workspace", "scoped_admin"),
        cmd("bulldocs.publish", "bulldocs", "ingest")
      ]
    }
  end

  defp cmd(id, noun, tier) do
    %{
      "id" => id,
      "noun" => noun,
      "verb" => id |> String.split(".") |> List.last(),
      "summary" => "…",
      "http" => %{"method" => "GET", "path_template" => "/v1/#{noun}"},
      "auth_tier" => tier,
      "args" => [],
      "flags" => [],
      "writes" => false,
      "batch" => false,
      "paginated" => false,
      "dry_run" => false,
      "default_output" => "table"
    }
  end

  defp tiers(manifest), do: Enum.map(manifest["commands"], & &1["auth_tier"]) |> MapSet.new()
  defp ids(manifest), do: Enum.map(manifest["commands"], & &1["id"]) |> MapSet.new()
  defp noun_names(manifest), do: Enum.map(manifest["nouns"], & &1["name"]) |> MapSet.new()

  describe "project/2 — existence-hiding, default-deny" do
    test "anon (none) sees ONLY 'none'-tier commands — zero write/admin/scoped_admin/ingest" do
      anon = Capabilities.project(superset(), "none")

      # The only command whose required tier 'none' lets an anon caller invoke.
      assert ids(anon) == MapSet.new(["doc.get"])

      # No non-'none' tier survives the projection.
      assert tiers(anon) == MapSet.new(["none"])
      refute "read" in tiers(anon)
      refute "write" in tiers(anon)
      refute "admin" in tiers(anon)
      refute "scoped_admin" in tiers(anon)
      refute "ingest" in tiers(anon)
    end

    test "anon learns zero admin / write / scoped_admin / ingest NOUN names" do
      anon = Capabilities.project(superset(), "none")

      # doc retains a visible command (doc.get); every other noun is hidden
      # because none of their commands survive for an anon caller.
      assert noun_names(anon) == MapSet.new(["doc"])
      refute "schema" in noun_names(anon)
      refute "webhook" in noun_names(anon)
      refute "workspace" in noun_names(anon)
      refute "bulldocs" in noun_names(anon)
    end

    test "auth_tier echo is overwritten with the caller's tier" do
      assert Capabilities.project(superset(), "none")["auth_tier"] == "none"
      assert Capabilities.project(superset(), "read")["auth_tier"] == "read"
      assert Capabilities.project(superset(), "admin")["auth_tier"] == "admin"
    end

    test "admin projection is a strict superset of the anon projection" do
      anon = Capabilities.project(superset(), "none")
      admin = Capabilities.project(superset(), "admin")

      assert MapSet.subset?(ids(anon), ids(admin))
      assert MapSet.subset?(noun_names(anon), noun_names(admin))

      # And strictly larger — admin sees commands anon does not.
      assert MapSet.size(ids(admin)) > MapSet.size(ids(anon))
    end

    test "admin sees read/write/admin globals plus scoped_admin (role-aware, never blanket-hidden)" do
      admin = Capabilities.project(superset(), "admin")

      assert "doc.get" in ids(admin)
      assert "doc.ls" in ids(admin)
      assert "doc.mutate" in ids(admin)
      assert "schema.apply" in ids(admin)
      assert "webhook.create" in ids(admin)
      # workspace.create (read-tier) is visible to admin (rank >= read).
      assert "workspace.create" in ids(admin)
      # contract rule #2: scoped_admin is visible to an authenticated caller,
      # never blanket client-side denied.
      assert "workspace.project-create" in ids(admin)
      # ingest secret is admin-equivalent here.
      assert "bulldocs.publish" in ids(admin)
    end

    test "read tier sees read + none + scoped_admin, but NOT write/admin/ingest" do
      read = Capabilities.project(superset(), "read")

      assert "doc.get" in ids(read)
      assert "doc.ls" in ids(read)
      # scoped_admin is NOT blanket-hidden from an authenticated (>= read) token.
      assert "workspace.project-create" in ids(read)
      # workspace.create is read-tier (RequireToken-only route) — a read-only
      # token CAN see and invoke it.
      assert "workspace.create" in ids(read)

      # write/admin/ingest verbs stay hidden from a read-only token.
      refute "doc.mutate" in ids(read)
      refute "schema.apply" in ids(read)
      refute "bulldocs.publish" in ids(read)
    end

    test "write-tier verb (doc.mutate) is visible to write but not anon" do
      write = Capabilities.project(superset(), "write")
      anon = Capabilities.project(superset(), "none")

      assert "doc.mutate" in ids(write)
      refute "doc.mutate" in ids(anon)
    end

    test "read-tier workspace.create is visible from read up, hidden from anon" do
      read = Capabilities.project(superset(), "read")
      write = Capabilities.project(superset(), "write")
      anon = Capabilities.project(superset(), "none")

      assert "workspace.create" in ids(read)
      assert "workspace.create" in ids(write)
      refute "workspace.create" in ids(anon)
    end

    test "etag is recomputed and differs between tiers (drives 304 + tier-keyed cache)" do
      anon = Capabilities.project(superset(), "none")
      admin = Capabilities.project(superset(), "admin")

      assert is_binary(anon["etag"]) and anon["etag"] != ""
      assert is_binary(admin["etag"]) and admin["etag"] != ""
      assert anon["etag"] != admin["etag"]
      # Not the seed etag — it was recomputed over the projected body.
      assert anon["etag"] != "W/\"seed\""
    end
  end

  describe "visible?/2 — the default-deny predicate" do
    test "global ladder: caller rank must be >= required rank" do
      assert Capabilities.visible?("none", "none")
      assert Capabilities.visible?("read", "read")
      assert Capabilities.visible?("read", "admin")
      assert Capabilities.visible?("write", "admin")
      refute Capabilities.visible?("write", "read")
      refute Capabilities.visible?("admin", "write")
      refute Capabilities.visible?("read", "none")
    end

    test "scoped_admin: hidden from anon, visible to any authenticated caller" do
      refute Capabilities.visible?("scoped_admin", "none")
      assert Capabilities.visible?("scoped_admin", "read")
      assert Capabilities.visible?("scoped_admin", "write")
      assert Capabilities.visible?("scoped_admin", "admin")
    end

    test "ingest: visible only to admin/ingest, never to anon/read/write" do
      refute Capabilities.visible?("ingest", "none")
      refute Capabilities.visible?("ingest", "read")
      refute Capabilities.visible?("ingest", "write")
      assert Capabilities.visible?("ingest", "admin")
      assert Capabilities.visible?("ingest", "ingest")
    end

    test "unknown required tier defaults to deny" do
      refute Capabilities.visible?("bogus", "admin")
    end
  end
end
