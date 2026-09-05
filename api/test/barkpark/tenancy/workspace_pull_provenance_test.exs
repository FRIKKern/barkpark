defmodule Barkpark.Tenancy.WorkspacePullProvenanceTest do
  @moduledoc """
  PULLED DATA KNOWS WHERE IT CAME FROM (PDS-D15/D16/D50).

  Two halves, both proven against the real DB / real HTTP edge:

    * the ACCESSORS — `Tenancy.pull_provenance/2` + `set_pull_provenance/3`
      round-trip a stamp under `workspaces.settings["pull_provenance"]`, nested
      BY DATASET SLUG so sibling datasets never clobber each other, and so the
      shipped `theme` / `plugins` / `chat` keys survive a stamp untouched.
    * the HTTP STAMP — `POST /api/workspaces/:slug/import` writes the stamp from
      the bundle manifest's additive fields plus `pulled_at`, and answers a
      `provenance` receipt on BOTH the clean and the merge success path.

  Plus the honest-refusal half of PDS-D50: an empty or truncated body is a 422
  `invalid_bundle`, not the MatchError-driven 500 it used to be.

  These assertions are FRESH by necessity — every import assertion in
  `workspace_controller_test.exs` is key-by-key subset matching, so the existing
  suite would stay green against a `provenance` key that was never written.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.WorkspaceBundle

  @stamp %{
    "source_server" => "https://guerrilla.barkpark.cloud",
    "source_workspace" => "default",
    "source_dataset" => "production",
    "exported_at" => "2026-07-19T12:00:00Z",
    "profile" => "dev",
    "pulled_at" => "2026-07-19T12:05:00Z"
  }

  describe "Tenancy.pull_provenance/2 + set_pull_provenance/3" do
    test "round-trips a stamp keyed by dataset slug" do
      ws = TenancyFixtures.create_workspace!()

      assert Tenancy.pull_provenance(ws, "production") == %{}

      assert {:ok, ws} = Tenancy.set_pull_provenance(ws, "production", @stamp)
      assert Tenancy.pull_provenance(ws, "production") == @stamp

      # ...and it is DURABLE, not just in the returned struct.
      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.pull_provenance(reloaded, "production") == @stamp
    end

    test "sibling datasets do NOT clobber each other (the two-level nesting)" do
      ws = TenancyFixtures.create_workspace!()
      staging = Map.put(@stamp, "source_dataset", "staging")

      {:ok, _} = Tenancy.set_pull_provenance(ws.id, "production", @stamp)
      {:ok, _} = Tenancy.set_pull_provenance(ws.id, "staging", staging)

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.pull_provenance(reloaded, "production") == @stamp
      assert Tenancy.pull_provenance(reloaded, "staging") == staging

      assert Tenancy.pull_provenance(reloaded) |> Map.keys() |> Enum.sort() ==
               ~w(production staging)

      # A dataset with no stamp is not covered by a sibling's.
      assert Tenancy.pull_provenance(reloaded, "review") == %{}
    end

    test "re-stamping the SAME dataset replaces that slug only" do
      ws = TenancyFixtures.create_workspace!()
      {:ok, _} = Tenancy.set_pull_provenance(ws.id, "production", @stamp)
      {:ok, _} = Tenancy.set_pull_provenance(ws.id, "staging", @stamp)

      newer = Map.put(@stamp, "pulled_at", "2026-07-20T09:00:00Z")
      {:ok, _} = Tenancy.set_pull_provenance(ws.id, "production", newer)

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.pull_provenance(reloaded, "production") == newer
      assert Tenancy.pull_provenance(reloaded, "staging") == @stamp
    end

    test "the shipped theme / plugins / chat keys survive a stamp" do
      ws = TenancyFixtures.create_workspace!()
      {:ok, ws} = Tenancy.set_workspace_plugin_settings(ws, %{"media" => %{"enabled" => true}})
      {:ok, ws} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "cloud"})

      {:ok, _} = Tenancy.set_pull_provenance(ws.id, "production", @stamp)

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.workspace_plugin_settings(reloaded) == %{"media" => %{"enabled" => true}}
      assert Tenancy.workspace_chat_settings(reloaded) == %{"execution_profile" => "cloud"}
      assert Tenancy.pull_provenance(reloaded, "production") == @stamp
    end

    test "guards: nil workspace, nil/garbage settings, bad slug, bad value, unknown id" do
      ws = TenancyFixtures.create_workspace!()

      # `workspaces.settings` is NOT NULL at the DB level (a `SET settings = NULL`
      # raises 23502), so a nil-settings row can only reach these functions
      # in-memory — from a legacy struct or a partial select. It still must not
      # raise: this read sits on the boot path.
      assert Tenancy.pull_provenance(%{ws | settings: nil}, "production") == %{}
      assert Tenancy.pull_provenance(%{ws | settings: nil}) == %{}

      # A garbage `pull_provenance` bag (hand-edited settings) degrades, never raises.
      junk = %{ws | settings: %{"pull_provenance" => "not-a-map"}}
      assert Tenancy.pull_provenance(junk, "production") == %{}
      assert Tenancy.pull_provenance(junk) == %{}

      shallow = %{ws | settings: %{"pull_provenance" => %{"production" => "not-a-map"}}}
      assert Tenancy.pull_provenance(shallow, "production") == %{}

      assert Tenancy.pull_provenance(nil, "production") == %{}
      assert Tenancy.pull_provenance(ws, nil) == %{}
      assert Tenancy.pull_provenance(nil) == %{}

      assert Tenancy.set_pull_provenance(ws, "production", "nope") ==
               {:error, :invalid_provenance}

      assert Tenancy.set_pull_provenance(ws, nil, @stamp) == {:error, :invalid_provenance}

      assert Tenancy.set_pull_provenance(Ecto.UUID.generate(), "production", @stamp) ==
               {:error, :not_found}

      # ...and a workspace whose bag is garbage can still be stamped — the write
      # replaces the bad bag rather than merging into it.
      {:ok, _} = Tenancy.set_pull_provenance(junk, "production", @stamp)
      assert Tenancy.pull_provenance(Tenancy.get_workspace_by_id(ws.id), "production") == @stamp
    end
  end

  describe "POST /api/workspaces/:slug/import — the provenance receipt" do
    test "clean import stamps the workspace and returns a provenance receipt", %{conn: conn} do
      raw_admin = "ws-prov-clean-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(
          %{name: "Provenance Clean WS"},
          admin_token(raw_admin)
        )

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} =
        WorkspaceBundle.export(target.id,
          profile: :dev,
          source_server: "https://guerrilla.barkpark.cloud"
        )

      ws_slug = target.slug
      clean_target!(target)

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{ws_slug}/import", bundle)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      prov = body["provenance"]
      assert prov["stamped"] == true
      assert prov["workspace"] == ws_slug

      # A whole-workspace bundle stamps every dataset the BUNDLE carries — which
      # is not simply "every dataset the workspace owns": `dataset_slugs_for/1`
      # drops a slug a sibling workspace also owns (fail-closed, PDS-D29). So
      # assert the two properties that are actually true: the dataset the
      # imported document lives in IS stamped, and nothing outside the
      # workspace's own datasets is.
      assert "test" in prov["datasets"]
      assert prov["datasets"] -- carried_dataset_slugs(ws_slug) == []
      assert prov["stamp"]["source_server"] == "https://guerrilla.barkpark.cloud"
      assert prov["stamp"]["source_workspace"] == ws_slug
      assert prov["stamp"]["profile"] == "dev"
      assert is_binary(prov["stamp"]["exported_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(prov["stamp"]["pulled_at"])

      # DURABLE — the same stamp is readable off the re-imported workspace row.
      imported = Tenancy.get_workspace_by_slug(ws_slug)
      stored = Tenancy.pull_provenance(imported, hd(prov["datasets"]))
      assert stored["source_server"] == "https://guerrilla.barkpark.cloud"
      assert stored["profile"] == "dev"
      assert stored["pulled_at"] == prov["stamp"]["pulled_at"]
    end

    test "merge import stamps too and its receipt rides beside mode:merge", %{conn: conn} do
      Application.put_env(:barkpark, :allow_bundle_import, true)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

      raw_admin = "ws-prov-merge-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(
          %{name: "Provenance Merge WS"},
          admin_token(raw_admin)
        )

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} = WorkspaceBundle.export(target.id, source_server: "https://origin.example")
      ws_slug = target.slug

      # MERGE runs over the still-populated workspace — no clean_target! here.
      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{ws_slug}/import?mode=merge", bundle)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["mode"] == "merge"

      prov = body["provenance"]
      assert prov["stamped"] == true
      assert prov["workspace"] == ws_slug
      assert prov["stamp"]["source_server"] == "https://origin.example"
      assert prov["stamp"]["profile"] == "full"

      imported = Tenancy.get_workspace_by_slug(ws_slug)

      assert Tenancy.pull_provenance(imported, hd(prov["datasets"]))["source_server"] ==
               "https://origin.example"
    end

    test "a dataset-narrowed bundle stamps ONLY that dataset slug", %{conn: conn} do
      raw_admin = "ws-prov-ds-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Provenance DS WS"}, admin_token(raw_admin))

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _staging} = Tenancy.create_dataset(project, %{slug: "staging", name: "Staging"})
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} = WorkspaceBundle.export(target.id, dataset: "staging")
      ws_slug = target.slug
      clean_target!(target)

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{ws_slug}/import", bundle)

      assert resp.status == 200
      prov = Jason.decode!(resp.resp_body)["provenance"]
      assert prov["datasets"] == ["staging"]

      imported = Tenancy.get_workspace_by_slug(ws_slug)
      assert Tenancy.pull_provenance(imported, "staging")["source_dataset"] == "staging"

      # Every SIBLING dataset the workspace owns stays unstamped — the narrowing
      # is real, not an artifact of a slug the workspace never had.
      for slug <- carried_dataset_slugs(ws_slug), slug != "staging" do
        assert Tenancy.pull_provenance(imported, slug) == %{},
               "sibling dataset #{slug} must NOT inherit the staging stamp"
      end
    end
  end

  describe "PDS-D50 — a body that cannot be a bundle is 422, never 500" do
    setup do
      raw_admin = "ws-invalid-bundle-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])
      %{raw_admin: raw_admin}
    end

    test "a ZERO-BYTE body → 422 invalid_bundle (clean path)", ctx do
      resp = import_body(ctx, "", "")

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_bundle"
    end

    test "a TRUNCATED bundle → 422 invalid_bundle (what a dropped stream produces)", ctx do
      {:ok, target} =
        Tenancy.create_workspace_with_owner(
          %{name: "Truncated WS"},
          admin_token(ctx.raw_admin)
        )

      {:ok, bundle} = WorkspaceBundle.export(target.id)
      truncated = binary_part(bundle, 0, div(byte_size(bundle), 3))

      resp = import_body(ctx, truncated, "")

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "invalid_bundle"
      assert body["error"]["message"] =~ "bundle"
    end

    test "a zero-byte body on the MERGE path → 422 invalid_bundle too", ctx do
      Application.put_env(:barkpark, :allow_bundle_import, true)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

      resp = import_body(ctx, "", "?mode=merge")

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_bundle"
    end

    test "the CONTROL still holds: an unknown mode is 422 invalid_import_mode", ctx do
      resp = import_body(ctx, "", "?mode=bogus")

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_import_mode"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp import_body(%{raw_admin: raw_admin}, body, query) do
    scoped_conn()
    |> authed(raw_admin)
    |> put_req_header("content-type", "application/x-tar")
    |> post("/api/workspaces/any-slug/import" <> query, body)
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  # The dataset slugs a whole-workspace bundle of `ws_slug` carries — read live
  # off the DB, because the default dataset slug differs per environment.
  defp carried_dataset_slugs(ws_slug) do
    ws = Tenancy.get_workspace_by_slug(ws_slug)

    %{rows: rows} =
      Repo.query!(
        "SELECT d.slug FROM datasets d JOIN projects p ON p.id = d.project_id " <>
          "WHERE p.workspace_id = $1",
        [Ecto.UUID.dump!(ws.id)]
      )

    Enum.map(rows, fn [slug] -> slug end)
  end

  defp admin_token(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token
  end

  # Delete the workspace so the copy-strategy bundle members re-import into a
  # CLEAN scope, then purge the two FK-less audit tables the cascade cannot
  # reach (same trick the engine round-trip and the controller suite use).
  defp clean_target!(target) do
    {:ok, _} = Tenancy.delete_workspace(target)
    {:ok, ws_bin} = Ecto.UUID.dump(target.id)

    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1", [ws_bin])
      Repo.query!("DELETE FROM audit_export_sinks WHERE workspace_id = $1", [ws_bin])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end

    refute Tenancy.get_workspace_by_slug(target.slug)
  end
end
