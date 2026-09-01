defmodule BarkparkWeb.TicketsAttachmentsSessionPipelineTest do
  @moduledoc """
  The `:session_token_root` bucket's missing gates (task-298e4a93456b1fc3).

  `GET /v1/tickets/inbox/:id/attachments/:asset_id` is the ONE route on
  `:session_token_root`. Its sibling bucket `:token_root` is
  `[:api, :require_token, RequireWriteForMutation]`, so it inherits
  `DeriveWorkspaceFromToken` (from `:api`) and `PublicRead` (from
  `:require_token`). `:session_token_root` was written as a hand-copy of `:api`'s
  SHAPE and received neither, which admitted three classes on a route that
  streams outsider-uploaded BYTES:

    * (A) TIER — a `public-read` token (the tier `TokenController` mints for
      public websites, shipped embedded in client JS) is a valid `kind: "api"`
      token, so `OptionalSessionToken` assigned it and the controller's
      `require_operator/1` (a non-nil check) admitted it. 200 + bytes.
    * (A') SHARE SURFACE — `OptionalSessionToken` does not apply
      `RequireToken.share_token_off_surface?/2` (which `OptionalToken` DOES), so
      a scope-bound share token was admitted on a route carrying no
      `workspace_slug` path param.
    * (B/C) TENANCY → LEAK — with no `DeriveWorkspaceFromToken` ahead of
      `AssignDefaultScope`, `operator_scope/1` resolved the seeded **Default**
      workspace for EVERY caller, so a token bound to workspace B streamed
      Default-workspace attachment bytes.
    * (D) CRASH — the route declares no `:dataset` segment, so
      `operator_dataset/1`'s `Map.get(conn.params, "dataset", "production")`
      handed a LIST straight to `Content.get_document/4` on `?dataset[]=x`;
      `scope_to_dataset` built `where(x.dataset == ^["x"])` and `Repo.one`
      raised `Ecto.Query.CastError`.

  Every test dispatches through the REAL endpoint pipeline. The legitimate
  operator is the positive control IN THE SAME RUN: it proves the fixture holds
  readable bytes, so a refusal above is a refusal and not an empty read.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.RateLimiterSandbox
  import Phoenix.ConnTest
  import Plug.Conn

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.TicketsAttachmentsController, as: Controller

  @endpoint BarkparkWeb.Endpoint

  @dataset "production"
  @pdf <<"%PDF-1.4\n1 0 obj\n<< >>\nendobj\n">>

  setup :reset_rate_limiter!

  setup do
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} = Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})
    Barkpark.Plugins.Media.Codelists.seed_all()

    # A generous rate-limit budget so a shared IP bucket can never turn one of
    # these auth outcomes into a stray 429.
    :ets.delete_all_objects(:barkpark_rate_limiter)

    # The attachment lives in the seeded DEFAULT workspace/project — exactly the
    # scope `AssignDefaultScope` hands every caller when nothing derived one.
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    key = %{id: "key-A", dataset: @dataset, workspace_id: ws.id, project_id: project.id}

    ticket = insert_ticket_in_scope!(key.id, ws, project)

    created =
      Controller.create(assign(build_conn(), :ticket_key, key), %{
        "id" => ticket,
        "file" => upload(@pdf, "doc.pdf", "application/pdf")
      })

    asset_id = json_response(created, 201)["attachment"]["asset_id"]
    path = "/v1/tickets/inbox/#{ticket}/attachments/#{asset_id}"

    # The LEGITIMATE operator: a read token minted INTO the Default workspace —
    # the one principal that should still see these bytes.
    operator_raw = mint_token!(["read"], ws.id)

    %{path: path, ticket: ticket, default_ws: ws, operator_raw: operator_raw}
  end

  # ── POSITIVE CONTROL — the fixture is real and the legitimate read works ───

  test "POSITIVE CONTROL: the Default-workspace operator still streams the bytes → 200",
       %{path: path, operator_raw: operator_raw} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{operator_raw}")
      |> get(path)

    assert conn.status == 200
    assert response(conn, 200) == @pdf
  end

  test "POSITIVE CONTROL: the Studio SESSION cookie path still streams the bytes → 200",
       %{path: path, operator_raw: operator_raw} do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"api_token" => operator_raw})
      |> get(path)

    assert conn.status == 200
    assert response(conn, 200) == @pdf
  end

  # ── (A) TIER — a public-read token must never reach this surface ──────────

  test "(A) a public-read token bound to the SAME workspace is refused, not served bytes",
       %{path: path, default_ws: ws} do
    public_raw = mint_token!(["public-read"], ws.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{public_raw}")
      |> get(path)

    assert conn.status in [401, 403]
    refute conn.resp_body == @pdf
  end

  test "(A) a token minted [public-read, read] is still the public tier (membership, not equality)",
       %{path: path, default_ws: ws} do
    public_raw = mint_token!(["public-read", "read"], ws.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{public_raw}")
      |> get(path)

    assert conn.status in [401, 403]
    refute conn.resp_body == @pdf
  end

  test "(A) a public-read token presented via the SESSION COOKIE is refused too",
       %{path: path, default_ws: ws} do
    public_raw = mint_token!(["public-read"], ws.id)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"api_token" => public_raw})
      |> get(path)

    assert conn.status in [401, 403]
    refute conn.resp_body == @pdf
  end

  # ── (A') SHARE SURFACE — a scope-bound share token is off-surface here ────

  test "(A') a scope-bound share token is refused on this flat route", %{path: path} do
    share_raw = mint_share_token!()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{share_raw}")
      |> get(path)

    assert conn.status in [401, 403]
    refute conn.resp_body == @pdf
  end

  # ── (B/C) TENANCY → LEAK — the scope must follow the TOKEN ────────────────

  test "(B/C) a workspace-B token does NOT read the Default workspace's attachment bytes",
       %{path: path} do
    foreign_raw = foreign_workspace_token!()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{foreign_raw}")
      |> get(path)

    # The BYTES are the assertion — a status-only check would pass on a 200
    # carrying an error envelope, and a 404 that still leaked would be worse.
    refute conn.resp_body == @pdf
    assert conn.status == 404
  end

  test "(B/C) the same workspace-B token, over the SESSION COOKIE, is scoped identically",
       %{path: path} do
    foreign_raw = foreign_workspace_token!()

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"api_token" => foreign_raw})
      |> get(path)

    refute conn.resp_body == @pdf
    assert conn.status == 404
  end

  # ── (D) CRASH — a non-string `dataset` query param ───────────────────────

  test "(D) ?dataset[]=x returns a clean 4xx, not a raised CastError / 500",
       %{path: path, operator_raw: operator_raw} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{operator_raw}")
      |> get(path <> "?dataset[]=x")

    assert conn.status in 400..499
  end

  test "(D) ?dataset[k]=v (a MAP) returns a clean 4xx, not a 500",
       %{path: path, operator_raw: operator_raw} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{operator_raw}")
      |> get(path <> "?dataset[k]=v")

    assert conn.status in 400..499
  end

  test "(D) a well-formed ?dataset= string is still honoured (no over-clamp)",
       %{path: path, operator_raw: operator_raw} do
    # The ticket lives in "production", so a "staging" read must 404 — proving
    # the guard rejects the SHAPE, not the parameter.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{operator_raw}")
      |> get(path <> "?dataset=staging")

    assert conn.status == 404
    refute conn.resp_body == @pdf
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp mint_token!(permissions, workspace_id) do
    raw = "op-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
    label = "T-" <> Enum.join(permissions, "-")
    {:ok, _} = Auth.create_token(raw, label, @dataset, permissions, workspace_id)
    raw
  end

  defp foreign_workspace_token! do
    other_ws = TenancyFixtures.create_workspace!()
    _other_project = TenancyFixtures.create_project!(other_ws)
    mint_token!(["read"], other_ws.id)
  end

  # A scope-bound SHARE token — `share_scope` set, `kind: "api"`, the exact
  # shape `RequireToken.share_token_off_surface?/2` refuses on a route with no
  # `workspace_slug` path param. Inserted directly rather than through
  # `Auth.create_share_token/5`, whose validation demands a live edit-Share row.
  defp mint_share_token! do
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    raw = "bpshare_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "share-edit fixture",
        dataset: @dataset,
        permissions: ["share-edit-paper"],
        workspace_id: ws.id,
        share_scope: "#{ws.slug}/#{project.slug}/#{@dataset}"
      })
      |> Repo.insert()

    raw
  end

  defp insert_ticket_in_scope!(key_id, ws, project) do
    doc_id = "ticket-" <> Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "ticket",
      dataset: @dataset,
      status: "open",
      rev: "1",
      workspace_id: ws.id,
      project_id: project.id,
      content: %{"key_id" => key_id, "status" => "open", "messages" => []}
    })

    doc_id
  end

  defp upload(bytes, filename, content_type) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bptk-pipe-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: filename, content_type: content_type}
  end
end
