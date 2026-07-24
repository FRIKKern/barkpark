defmodule BarkparkWeb.WorkspaceImportTemplateJourneyTest do
  @moduledoc """
  task-96d8ab2b582818a4 — the MVP-0 support chain's merge-import, reproduced
  with the REAL astro-search-starter template artifacts through the REAL HTTP
  surfaces, end to end. The third live fire died on the LAST call of this exact
  sequence: `POST /api/workspaces/:ws/import?mode=merge` answered 500
  `internal_error` in 251ms with no error line in the captured journal, while
  CI's earlier box-scenario test passed with a SYNTHETIC bundle (two
  empty-field schemas, one unpublished doc, no references). This test carries
  the real divergences the synthetic bundle lacked:

    * the manifest schema (`schemas/entry.json`) with reference + arrayOf
      reference fields — not `"fields" => []`;
    * the full seed corpus (`seed.json`, 35 documents) written through the
      SCOPED mutate endpoint and then PUBLISHED, exactly like
      `internal/bootstrap`'s seedAndPublish (createOrReplace lands drafts; the
      publish pass is a second mutate call of `{publish: {id, type}}`);
    * the `content_edges` rows the reference graph materialises;
    * the REAL ensure path on both sides (`POST /api/workspaces` →
      `create_workspace_with_owner`, which also writes the owner MEMBERSHIP row
      the engine-level fixtures never created);
    * export via the real HTTP controller with the support chain's exact query
      (`?profile=dev&dataset=production&source_server=…`).

  The journey (verbatim from the round-3 transcript):

      parent:  POST /api/workspaces {name, slug}          (template ensureWorkspace)
               POST /w/<ws>/p/default/v1/schemas/production
               POST /w/<ws>/p/default/v1/data/mutate/production   (seed)
               POST /w/<ws>/p/default/v1/data/mutate/production   (publish pass)
               GET  /api/workspaces/<ws>/export?profile=dev&dataset=production
      box:     parent rows purged (a fresh box never had them)
               POST /api/workspaces {name, slug}          (supportEnsureWorkspaceStep)
               POST /api/workspaces/<ws>/import?mode=merge (bp cloud workspace import --merge)

  Modeled gaps vs the live box, stated honestly (charter discipline):

    * bootstrap steps 4/5 (read-token mint, webhook upsert) are skipped — both
      write ONLY dev-profile-DENIED tables (`api_tokens`, `webhooks`), which
      can never enter the dev bundle, so they cannot change the import;
    * the support chain's parent-side roster row + ledger-token mint land in
      the parent's DEFAULT workspace / denied tables — also outside the bundle;
    * the box's Bootstrap plugin schemas live in the seeded Default workspace
      (same as live); Oban/background concurrency is absent under the SQL
      sandbox, so a live-only interleaving cannot be reproduced here.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, Tenancy}

  @template_dir Path.expand(
                  "../../../../internal/provisioner/catalog/templates/astro-search-starter",
                  __DIR__
                )

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp scoped_count(sql, ws_id) do
    {:ok, ws_bin} = Ecto.UUID.dump(ws_id)
    %{rows: [[cnt]]} = Repo.query!(sql, [ws_bin])
    cnt
  end

  defp doc_count(ws_id),
    do: scoped_count("SELECT count(*) FROM documents WHERE workspace_id = $1", ws_id)

  defp edge_count(ws_id) do
    scoped_count(
      "SELECT count(*) FROM content_edges ce JOIN documents d ON d.id = ce.from_id " <>
        "WHERE d.workspace_id = $1",
      ws_id
    )
  end

  test "the template-launched parent's dev/dataset bundle merge-imports into an ensured same-slug shell over HTTP",
       %{conn: conn} do
    Application.put_env(:barkpark, :allow_bundle_import, true)
    on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

    schema_body = File.read!(Path.join(@template_dir, "schemas/entry.json"))
    seed_body = File.read!(Path.join(@template_dir, "seed.json"))

    raw_admin = "tpl-journey-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw_admin, "tpl journey admin", "test", ["read", "write", "admin"])

    slug = "tpl-journey-#{System.unique_integer([:positive])}"
    scoped = "/w/#{slug}/p/default/v1"

    # ── 1. PARENT — the template bootstrap's exact calls ─────────────────────
    resp =
      conn |> authed(raw_admin) |> post("/api/workspaces", %{"name" => slug, "slug" => slug})

    assert resp.status == 201, "parent ensure answered #{resp.status}: #{resp.resp_body}"
    parent_id = Jason.decode!(resp.resp_body)["workspace"]["id"]

    resp =
      conn
      |> authed(raw_admin)
      |> put_req_header("content-type", "application/json")
      |> post("#{scoped}/schemas/production", schema_body)

    assert resp.status in 200..299, "schema upsert answered #{resp.status}: #{resp.resp_body}"

    resp =
      conn
      |> authed(raw_admin)
      |> put_req_header("content-type", "application/json")
      |> post("#{scoped}/data/mutate/production", seed_body)

    assert resp.status in 200..299, "seed mutate answered #{resp.status}: #{resp.resp_body}"

    # Publish pass — bootstrap.seedAndPublish's second mutate call, verbatim.
    seed_ids =
      seed_body
      |> Jason.decode!()
      |> Map.fetch!("mutations")
      |> Enum.map(fn m ->
        get_in(m, ["createOrReplace", "_id"]) || get_in(m, ["create", "_id"])
      end)
      |> Enum.filter(&is_binary/1)

    assert length(seed_ids) > 30, "seed corpus unexpectedly small: #{length(seed_ids)} ids"

    publish_body =
      Jason.encode!(%{
        "mutations" =>
          Enum.map(seed_ids, fn id -> %{"publish" => %{"id" => id, "type" => "entry"}} end)
      })

    resp =
      conn
      |> authed(raw_admin)
      |> put_req_header("content-type", "application/json")
      |> post("#{scoped}/data/mutate/production", publish_body)

    assert resp.status in 200..299, "publish pass answered #{resp.status}: #{resp.resp_body}"

    # The parent is genuinely template-shaped before export — not vacuous.
    parent_docs = doc_count(parent_id)
    parent_edges = edge_count(parent_id)
    assert parent_docs >= length(seed_ids)

    # ── 2. EXPORT — the support chain's exact dev/dataset pull over HTTP ─────
    resp =
      conn
      |> authed(raw_admin)
      |> get(
        "/api/workspaces/#{slug}/export?profile=dev&dataset=production" <>
          "&source_server=https://parent.test"
      )

    assert resp.status == 200, "export answered #{resp.status}: #{resp.resp_body}"
    bundle = resp.resp_body
    assert byte_size(bundle) > 0

    # ── 3. THE BOX — the parent lives on another machine ─────────────────────
    {:ok, _} = Tenancy.delete_workspace(parent_id)
    refute Tenancy.get_workspace_by_slug(slug)

    # supportEnsureWorkspaceStep: a same-slug EMPTY shell through the REAL
    # create path (owner membership + Default project + production dataset).
    resp =
      conn |> authed(raw_admin) |> post("/api/workspaces", %{"name" => slug, "slug" => slug})

    assert resp.status == 201, "shell ensure answered #{resp.status}: #{resp.resp_body}"
    shell_id = Jason.decode!(resp.resp_body)["workspace"]["id"]
    refute shell_id == parent_id

    # ── 4. THE IMPORT the chain runs (bp cloud workspace import --merge) ─────
    resp =
      conn
      |> authed(raw_admin)
      |> put_req_header("content-type", "application/x-tar")
      |> post("/api/workspaces/#{slug}/import?mode=merge", bundle)

    body = Jason.decode!(resp.resp_body)

    assert resp.status == 200,
           "merge import answered #{resp.status} (the live box died here with a silent " <>
             "internal_error): #{resp.resp_body}"

    assert body["mode"] == "merge"
    assert body["total_rows"] > 0
    assert is_map(body["tables"])
    assert body["tables"]["documents"] > 0

    # Provenance receipt: the dataset-narrowed pull stamps its one dataset.
    assert body["provenance"]["stamped"] == true
    assert body["provenance"]["datasets"] == ["production"]

    # The shell was adopted: the bundle's workspace owns the slug again and the
    # template content really landed at the dev/dataset grain.
    assert Tenancy.get_workspace_by_slug(slug).id == parent_id

    assert scoped_count("SELECT count(*) FROM workspaces WHERE id = $1", shell_id) == 0
    assert doc_count(parent_id) == parent_docs
    assert edge_count(parent_id) == parent_edges

    assert scoped_count(
             "SELECT count(*) FROM schema_definitions WHERE workspace_id = $1",
             parent_id
           ) == 1
  end
end
