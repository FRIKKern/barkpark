defmodule Barkpark.Plugins.Tickets.ThreadTest do
  @moduledoc """
  The embedded thread + pure lifecycle state machine (charter Decisions 2 & 3).

  Covers: the pure `transition/2`; create (first message, credential-stamped
  author, initial state); operator answer / submitter auto-reopen / operator
  close; the seen stamp; the 200-message cap; and fail-closed key scoping
  (a foreign key gets `:not_found`, never a leak).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Tickets.Thread
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    ws = TenancyFixtures.create_workspace!()
    scope = [workspace_id: ws.id]
    register_ticket_schema!(scope)

    key = mk_key(ws, "Kari")
    %{ws: ws, scope: scope, key: key}
  end

  defp mk_key(ws, name) do
    %{
      id: "key-#{System.unique_integer([:positive])}",
      name: name,
      workspace_id: ws.id,
      dataset: @dataset
    }
  end

  defp register_ticket_schema!(scope) do
    for schema_def <- Barkpark.Plugins.Tickets.register_schemas([]) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp content(%Document{content: c}), do: c

  # ── Pure state machine ───────────────────────────────────────────────────

  describe "transition/2 (pure)" do
    test "derives every status from the action, never from prior state" do
      assert Thread.transition("closed", :create) == "open"
      assert Thread.transition("open", :answer) == "answered"
      assert Thread.transition("answered", :reply) == "open"
      assert Thread.transition("closed", :reply) == "open"
      assert Thread.transition("answered", :close) == "closed"
    end

    test "action_for maps author kind to lifecycle action" do
      assert Thread.action_for("submitter") == :reply
      assert Thread.action_for("operator") == :answer
    end
  end

  # ── Create ───────────────────────────────────────────────────────────────

  describe "create/2" do
    test "builds the doc with the first message, open status, and a waiting stamp", %{key: key} do
      assert {:ok, %Document{} = doc} =
               Thread.create(key, %{subject: "Login broken", body: "I can't sign in"})

      c = content(doc)
      assert c["subject"] == "Login broken"
      assert c["status"] == "open"
      assert c["key_id"] == key.id
      assert c["key_name"] == "Kari"
      assert c["submitter_seen_at"] == nil
      assert is_binary(c["waiting_since"])

      assert [msg] = c["messages"]
      assert msg["author_kind"] == "submitter"
      # Author is stamped from the CREDENTIAL, not the body.
      assert msg["author_name"] == "Kari"
      assert msg["body"] == "I can't sign in"
      assert msg["attachments"] == []
      assert is_binary(msg["id"])
    end

    test "keeps only binary asset ids in attachments", %{key: key} do
      assert {:ok, doc} =
               Thread.create(key, %{
                 subject: "Screenshot",
                 body: "see attached",
                 attachments: ["asset-1", nil, "", "asset-2", 42]
               })

      assert [msg] = content(doc)["messages"]
      assert msg["attachments"] == ["asset-1", "asset-2"]
    end

    test "rejects a blank subject or body", %{key: key} do
      assert {:error, :subject_required} = Thread.create(key, %{subject: "  ", body: "hi"})
      assert {:error, :body_required} = Thread.create(key, %{subject: "hi", body: ""})
    end

    test "bounds the low-trust surface: oversized subject/body and attachment spam are rejected",
         %{key: key} do
      # 201 > the 200-byte cap — and, crucially, subjects must be rejected
      # BEFORE the varchar(255) `title` column turns them into a raw DB error.
      assert {:error, :subject_too_long} =
               Thread.create(key, %{subject: String.duplicate("s", 201), body: "hi"})

      assert {:error, :body_too_long} =
               Thread.create(key, %{subject: "hi", body: String.duplicate("b", 65_537)})

      assert {:error, :too_many_attachments} =
               Thread.create(key, %{
                 subject: "hi",
                 body: "hi",
                 attachments: Enum.map(1..11, &"asset-#{&1}")
               })

      # Exactly at the bounds is fine.
      assert {:ok, _} =
               Thread.create(key, %{
                 subject: String.duplicate("s", 200),
                 body: String.duplicate("b", 65_536),
                 attachments: Enum.map(1..10, &"asset-#{&1}")
               })
    end
  end

  # ── Lifecycle: answer / reply / close ────────────────────────────────────

  describe "append/4 + close/1 lifecycle" do
    setup %{key: key} do
      {:ok, doc} = Thread.create(key, %{subject: "Q", body: "how?"})
      %{ticket: doc}
    end

    test "operator answer flips to answered and stamps the operator author", %{ticket: ticket} do
      assert {:ok, answered} =
               Thread.append(ticket, {"operator", "Support Desk"}, "here's how", [])

      c = content(answered)
      assert c["status"] == "answered"
      assert length(c["messages"]) == 2
      last = List.last(c["messages"])
      assert last["author_kind"] == "operator"
      assert last["author_name"] == "Support Desk"
    end

    test "submitter reply on an answered ticket AUTO-REOPENS and resets waiting_since", %{
      ticket: ticket
    } do
      {:ok, answered} = Thread.append(ticket, {"operator", "Desk"}, "answer", [])
      answered_waiting = content(answered)["waiting_since"]

      # a tiny gap so the reset stamp is strictly newer
      Process.sleep(5)

      assert {:ok, reopened} = Thread.append(answered, {"submitter", "Kari"}, "still broken", [])
      c = content(reopened)
      assert c["status"] == "open"
      assert length(c["messages"]) == 3
      assert c["waiting_since"] != answered_waiting
    end

    test "operator answer clears a prior submitter_seen_at (so the seen signal tracks THIS answer)",
         %{ticket: ticket} do
      {:ok, answered} = Thread.append(ticket, {"operator", "Desk"}, "answer", [])
      {:ok, seen} = Thread.stamp_seen(answered)
      assert content(seen)["submitter_seen_at"] != nil

      assert {:ok, re_answered} = Thread.append(seen, {"operator", "Desk"}, "actually…", [])
      assert content(re_answered)["submitter_seen_at"] == nil
    end

    test "operator close flips to closed", %{ticket: ticket} do
      assert {:ok, closed} = Thread.close(ticket)
      assert content(closed)["status"] == "closed"
    end

    test "a blank reply body is rejected", %{ticket: ticket} do
      assert {:error, :body_required} = Thread.append(ticket, {"submitter", "Kari"}, "   ", [])
    end

    test "an oversized reply body or attachment spam is rejected", %{ticket: ticket} do
      assert {:error, :body_too_long} =
               Thread.append(ticket, {"submitter", "Kari"}, String.duplicate("b", 65_537), [])

      assert {:error, :too_many_attachments} =
               Thread.append(ticket, {"submitter", "Kari"}, "ok", Enum.map(1..11, &"a-#{&1}"))
    end
  end

  # ── Seen stamp ───────────────────────────────────────────────────────────

  describe "stamp_seen/1" do
    test "stamps submitter_seen_at when the ticket is answered", %{key: key} do
      {:ok, doc} = Thread.create(key, %{subject: "Q", body: "?"})
      {:ok, answered} = Thread.append(doc, {"operator", "Desk"}, "A", [])

      assert content(answered)["submitter_seen_at"] == nil
      assert {:ok, seen} = Thread.stamp_seen(answered)
      assert is_binary(content(seen)["submitter_seen_at"])
    end

    test "is a no-op while the ticket is still open (nothing to have seen)", %{key: key} do
      {:ok, doc} = Thread.create(key, %{subject: "Q", body: "?"})
      assert {:ok, unchanged} = Thread.stamp_seen(doc)
      assert content(unchanged)["submitter_seen_at"] == nil
    end
  end

  # ── Cap ──────────────────────────────────────────────────────────────────

  describe "thread cap" do
    test "the 200th append is fine; the 201st is rejected with :thread_full", %{
      key: key,
      scope: scope
    } do
      {:ok, doc} = Thread.create(key, %{subject: "big", body: "1"})

      # Fast-path the thread to exactly 200 messages by persisting a padded
      # content directly (200 real appends would be needlessly slow), then let
      # Thread.append re-read that state and hit the cap.
      full_messages =
        for n <- 1..200 do
          %{
            "id" => "m-#{n}",
            "author_kind" => "submitter",
            "author_name" => "Kari",
            "body" => "msg #{n}",
            "attachments" => [],
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        end

      padded = Map.put(doc.content, "messages", full_messages)

      {:ok, _} =
        Content.upsert_document(
          "ticket",
          %{
            "doc_id" => doc.doc_id,
            "type" => "ticket",
            "title" => doc.title,
            "content" => padded,
            "status" => doc.status
          },
          @dataset,
          scope
        )

      {:ok, at_cap} = Content.get_document(doc.doc_id, "ticket", @dataset, scope)
      assert length(at_cap.content["messages"]) == 200

      assert {:error, :thread_full} =
               Thread.append(at_cap, {"submitter", "Kari"}, "one too many", [])
    end
  end

  # ── Scoping (fail-closed, never leak) ────────────────────────────────────

  describe "owned_by_key? / get_for_key" do
    test "a key sees its own ticket", %{key: key} do
      {:ok, doc} = Thread.create(key, %{subject: "mine", body: "hi"})
      assert Thread.owned_by_key?(doc, key)

      id = Content.published_id(doc.doc_id)
      assert {:ok, %Document{}} = Thread.get_for_key(key, id)
    end

    test "a foreign key gets :not_found (404, never 403 — existence is not leaked)", %{
      ws: ws,
      key: key
    } do
      {:ok, doc} = Thread.create(key, %{subject: "mine", body: "hi"})
      other = mk_key(ws, "Mallory")

      refute Thread.owned_by_key?(doc, other)

      id = Content.published_id(doc.doc_id)
      assert {:error, :not_found} = Thread.get_for_key(other, id)
    end

    test "list_for_key returns only the calling key's tickets", %{ws: ws, key: key} do
      {:ok, _a} = Thread.create(key, %{subject: "a", body: "1"})
      {:ok, _b} = Thread.create(key, %{subject: "b", body: "2"})

      other = mk_key(ws, "Someone")
      {:ok, _c} = Thread.create(other, %{subject: "c", body: "3"})

      mine = Thread.list_for_key(key)
      assert length(mine) == 2
      assert Enum.all?(mine, &(&1.content["key_id"] == key.id))
    end
  end

  # ── Operator listing: the project-null seam ──────────────────────────────
  #
  # Keys bind at the WORKSPACE level (`Keys.mint` sets `workspace_id`, never a
  # project), so a ticket is created with the key's scope — `project_id` nil. An
  # operator viewing the inbox from a PROJECT-scoped Studio/HTTP context passes a
  # `project_id` in scope; `Content.list_documents`/`get_document` run
  # `scope_to_workspace/3`, which filters `project_id == ^project_id` with NO
  # null fallback. `Thread.list_for_operator/get_for_operator` therefore DROP the
  # project so the whole workspace's tickets stay visible — this is that guard.

  describe "operator listing scopes by workspace, not project" do
    test "a PROJECT-scoped operator context still sees key-created (project-null) tickets",
         %{ws: ws, key: key} do
      {:ok, doc} = Thread.create(key, %{subject: "workspace ticket", body: "hi"})

      # The operator is scoped to a project the ticket does NOT carry (tickets
      # are project-null). Without the project-drop this would return [].
      project_scoped = [
        workspace_id: ws.id,
        project_id: "proj-#{System.unique_integer([:positive])}"
      ]

      subjects =
        @dataset
        |> Thread.list_for_operator(project_scoped)
        |> Enum.map(& &1.content["subject"])

      assert "workspace ticket" in subjects

      # And the single-thread lookup an operator opens from that same context
      # must resolve too, not 404.
      id = Content.published_id(doc.doc_id)
      assert {:ok, %Document{}} = Thread.get_for_operator(id, @dataset, project_scoped)
    end
  end

  # ── Operator listing: the nil-workspace direction ────────────────────────
  #
  # The sibling block above pins the PROJECT drop. This one pins the WORKSPACE
  # direction, which used to run the opposite way.
  #
  # `operator_scope/1` used to be a bare `Keyword.delete(scope, :project_id)`,
  # so a scope carrying no `:workspace_id` reached
  # `Content.Scope.scope_to_workspace_or_global(q, nil, _)` — the query
  # UNTOUCHED, i.e. every tenant's tickets. That state is reachable: the conn
  # arm of `BarkparkWeb.ScopeHelpers.scope_opts/1` emits the `:shared_only`
  # sentinel, but the `%Socket{}` arm DROPS the key on a nil
  # `:current_workspace`, and `Barkpark.Plugins.Tickets.InboxLive` reads
  # through the socket arm. `get_for_operator/3` shares the helper, so the
  # inbox's answer/close handlers rode the same widened read.
  #
  # Both assertions below fail against the bare `Keyword.delete/2`: run them
  # against it and the listing comes back `["theirs", "mine"]` — two
  # workspaces through one un-narrowed read.
  #
  # The non-regression half is NOT re-proven here, deliberately.
  # `test/barkpark_web/empty_scope_shared_layer_test.exs:173` (":shared_only
  # means the shared layer in every request-reachable arm") already pins that
  # `:shared_only` resolves to `where(is_nil(x.workspace_id))` — the
  # shared/global layer — and never to zero rows, across every Scope arm. It
  # also could not be proven through this fixture: `Thread.create/2` resolves a
  # default workspace, so a genuinely NULL-workspace ticket is unreachable from
  # here.

  describe "operator reads narrow when no workspace resolves" do
    # The ticket schema is already registered by the outer setup:
    # `schema_definitions_name_dataset_null_dataset_id_index` makes
    # (name, dataset) unique regardless of workspace, so one registration
    # covers every workspace this block creates.
    setup %{ws: ws} do
      other_ws = TenancyFixtures.create_workspace!()

      {:ok, _mine} = Thread.create(mk_key(ws, "Kari"), %{subject: "mine", body: "hi"})

      {:ok, theirs} =
        Thread.create(mk_key(other_ws, "Ola"), %{subject: "theirs", body: "hi"})

      %{theirs: theirs}
    end

    # `[]` is literally what `scope_opts(%Socket{})` yields for the tenancy
    # keys when `:current_workspace` is unset; `[workspace_id: nil]` is the
    # same intent spelled with the key present, which `Keyword.put_new/3`
    # would have failed to narrow.
    for {label, scope} <- [{"an absent key", []}, {"an explicit nil", [workspace_id: nil]}] do
      test "#{label} yields the shared layer, not every tenant", %{theirs: theirs} do
        subjects =
          @dataset
          |> Thread.list_for_operator(unquote(scope))
          |> Enum.map(& &1.content["subject"])

        refute "theirs" in subjects
        refute "mine" in subjects

        id = Content.published_id(theirs.doc_id)
        assert {:error, :not_found} = Thread.get_for_operator(id, @dataset, unquote(scope))
      end
    end
  end
end
