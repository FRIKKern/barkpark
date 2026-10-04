defmodule BarkparkWeb.ActorLabelAtRestTest do
  @moduledoc """
  Owner ruling #32 item 1 (2026-10-03, task-43179d8d03efe969): a signed-in
  user's history and paper-access rows store the user ID, never the email.

  `revisions.actor_label` (kept indefinitely; UPDATE blocked by trigger) and
  `paper_access_log.actor_label` (90-day sweep) used to hold the editor's email,
  so an erased subject's address stayed at rest. New rows now carry
  `actor_kind: "user"` + `actor_id` and a NULL label; the reads
  (`GET /v1/data/history/...`, `GET /v1/papers/:slug/access`) resolve the label
  from the account, so readers still see who did it. Rows written before keep
  their stored email and stay redacted at read (see
  `erased_actor_label_redaction_test.exs`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Auth, Content, Repo}
  alias Barkpark.Accounts.Privacy
  alias Barkpark.Content.{CallerContext, PaperAccess}

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    email = "at-rest-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "a-long-enough-password-1"})

    ctx =
      CallerContext.with_actor(%CallerContext{principal_type: :user, user_id: user.id}, %{
        kind: "user",
        id: user.id,
        label: user.email
      })

    %{ws: ws, proj: proj, user: user, email: email, ctx: ctx}
  end

  test "a user's revision stores the id and no email; the history read still names them",
       %{conn: conn} = c do
    id = "at-rest-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "drafts." <> id, "title" => "V1"}, "test",
        caller_context: c.ctx,
        workspace_id: c.ws.id,
        project_id: c.proj.id
      )

    stored =
      Repo.all(
        from(r in "revisions",
          where: r.doc_id == ^("drafts." <> id) or r.doc_id == ^id,
          select: %{kind: r.actor_kind, id: r.actor_id, label: r.actor_label}
        )
      )

    assert stored != [], "no revision row was written — the at-rest check is vacuous"

    for row <- stored do
      assert row.kind == "user" and row.id == c.user.id
      assert is_nil(row.label), "a revision stored the editor's email at rest: #{row.label}"
    end

    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/history/test/post/#{id}")
      |> json_response(200)
      |> Jason.encode!()

    assert body =~ c.email, "the history read no longer names the editor"

    # After erasure the read shows the pseudonym, and the old email is nowhere.
    {:ok, _} = Privacy.erase_subject(Accounts.get_user(c.user.id))

    erased_body =
      scoped_conn()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/history/test/post/#{id}")
      |> json_response(200)
      |> Jason.encode!()

    refute erased_body =~ c.email
    assert erased_body =~ Accounts.get_user(c.user.id).email
  end

  test "a user's paper access row stores the id and no email", c do
    actor = %{kind: "user", id: c.user.id, label: c.email}
    entry = PaperAccess.entry("at-rest-paper", "production", c.ws.id, "view", actor)

    assert entry.actor_kind == "user"
    assert entry.actor_id == c.user.id
    assert is_nil(entry.actor_label), "the access row would store the reader's email at rest"

    # Token and share labels are names, not personal data: kept.
    token_entry =
      PaperAccess.entry("at-rest-paper", "production", c.ws.id, "view", %{
        kind: "api_token",
        id: "t1",
        label: "ci-token"
      })

    assert token_entry.actor_label == "ci-token"
  end

  test "the read resolves a stored-without-label user row to the account's email", c do
    [row] =
      Privacy.redact_actor_labels([%{actor_kind: "user", actor_id: c.user.id, actor_label: nil}])

    assert row.actor_label == c.email
  end
end
