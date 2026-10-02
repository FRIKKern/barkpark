defmodule BarkparkWeb.ErasedActorLabelRedactionTest do
  @moduledoc """
  An ERASED user's email is not readable through the history or paper-access
  reads (Run-4 Lane B erasure-completeness sweep).

  `Accounts.Privacy` documents erasure as "the subject's PII is scrubbed". A
  signed-in user's edits and paper views stamp `actor_label` with the user's
  EMAIL (`PaperViewer.principal_viewer/3` → `CallerContext.with_actor/2`) on
  `revisions` and `paper_access_log` — both append-only by design (the history
  trail, the 90-day access trail), so erasure cannot rewrite those rows. Before
  this, `GET /v1/data/history/…` and `GET /v1/papers/:slug/access` kept handing
  the erased subject's real email to every reader.

  The rows stay as they are (their retention is a recorded policy, out of this
  fix); the READ redacts: a `user` actor whose account has been erased is shown
  under its pseudonymised account email, never the stamped one.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Accounts.Privacy
  alias Barkpark.Content.CallerContext

  @email "erase-me-#{System.unique_integer([:positive])}@example.com"

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    {:ok, user} = Accounts.register_user(%{email: @email, password: "a-long-enough-password-1"})

    ctx =
      CallerContext.with_actor(%CallerContext{principal_type: :user, user_id: user.id}, %{
        kind: "user",
        id: user.id,
        label: user.email
      })

    id = "erase-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "drafts." <> id, "title" => "V1"}, "test",
        caller_context: ctx,
        workspace_id: ws.id,
        project_id: proj.id
      )

    %{user: user, doc_id: id}
  end

  defp history(conn, doc_id) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> get("/v1/data/history/test/post/#{doc_id}")
    |> json_response(200)
  end

  test "before erasure the history names the editor; after, it never shows the old email", %{
    conn: conn,
    user: user,
    doc_id: doc_id
  } do
    # Positive control: the stamp IS the email, so the redaction below is not
    # vacuously "there was never an email to hide".
    assert Jason.encode!(history(conn, doc_id)) =~ @email

    {:ok, _} = Privacy.erase_subject(Accounts.get_user(user.id))

    body = Jason.encode!(history(scoped_conn(), doc_id))
    refute body =~ @email, "the erased subject's email is still readable in document history"

    # The entry still says WHO (the pseudonymised account), not nothing.
    erased = Accounts.get_user(user.id)
    assert body =~ erased.email
  end

  test "Privacy.redact_actor_labels/1 leaves non-erased and non-user actors alone", %{user: user} do
    rows = [
      %{actor_kind: "user", actor_id: user.id, actor_label: @email},
      %{actor_kind: "api_token", actor_id: "t1", actor_label: "ci-token"},
      %{actor_kind: "anonymous", actor_id: nil, actor_label: nil}
    ]

    assert Privacy.redact_actor_labels(rows) == rows
  end
end
