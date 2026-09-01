defmodule Barkpark.Content.TaskBirthFenceTest do
  @moduledoc """
  PDS wave 28 — "a task is born adjudicated, and adoption-by-reparent cannot
  smuggle a bare row into the closure".

  Wave 24 closed both doors onto `content.disposition` on a LIVE row and wrote
  down what it could not close: "a `createOrReplace` on a BRAND-NEW id carrying
  `disposition: "parked"` and no trigger is STILL ACCEPTED … If that pinning
  test ever inverts, that is the intended signal that the birth fence landed."
  This file is that signal, plus the half of the problem a birth-scoped fence
  cannot see on its own.

  Three properties, each proven by a case that can FAIL:

    * **BIRTH** — the birth door may not accept an adjudication the sanctioned
      verb would refuse (`Writer.ensure_task_born_adjudicated/5`). Off-vocabulary
      term → 422. Hollow park (no reopen trigger) → 422. Complete adjudication →
      born. A birth with NO disposition is allowed and LOGGED, and the log is
      asserted — the promotion to a hard requirement is deliberately not this
      slice, so the honest state is a countable warning, not silence.
    * **ADOPTION** — a birth-scoped fence is structurally blind to reparenting
      (giving a task a `parent_id` later is an UPDATE, `prev_doc` non-nil), so
      `Mutations.ensure_adoption_adjudicated/4` catches the side door.
    * **THE BRIDGE** — the inbound GitHub webhook is UNAUTHENTICATED and its
      intake maps an unmatched error to HTTP 500, which GitHub redelivers
      forever. It is proven born ADJUDICATED (term + reason on the row read
      back) and proven NOT to 500, end-to-end through the real signed edge.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Settings, Signature}

  @token "barkpark-test-birth-fence-token"
  @dataset "production"
  @webhook_path "/v1/plugins/github/webhook"
  @webhook_secret "birth-fence-webhook-secret-abc123"
  @github_config_key Barkpark.Plugins.Github

  setup do
    {:ok, _} = Auth.create_token(@token, "test-birth-fence", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content(extra),
    do: Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

  defp mutate(ops, scope, extra \\ []) do
    Content.apply_mutations(ops, @dataset, Keyword.merge([source: :api] ++ scope, extra))
  end

  # A PLAIN `create` op with NO `_id` — the exact shape `bp task create` sends
  # (internal/cli/tasks_create_cmd.go). Proving this reaches the fence is what
  # refutes any doc-id-prefix scoping of the rule: there is no id to scope on.
  defp create_op(title, content),
    do: %{"create" => %{"_type" => "task", "title" => title, "content" => content}}

  defp content_of(doc_id, scope) do
    {:ok, doc} = Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)
    doc.content
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => task_content(content_extra)},
        @dataset,
        scope
      )

    doc
  end

  # ── BIRTH: the door may not accept what the verb would refuse ──────────────

  describe "birth fence — hard refusals" do
    test "a plain create with NO _id carrying a hollow park is REFUSED (bp task create shape)",
         %{scope: scope} do
      title = uniq("birth-hollow-park")

      assert {:error, {:invalid_task_content, %{"reopen_trigger" => [message]}}} =
               mutate([create_op(title, task_content(%{"disposition" => "parked"}))], scope)

      assert message =~ "required when a task is BORN"
      assert message =~ "bp task stage"

      # Nothing was written — a refusal here is side-effect-free (it runs before
      # :before_save, like every sibling gate on this chain).
      assert titled_task_ids(title) == []
    end

    test "an OFF-VOCABULARY birth term is REFUSED, and so is a mis-CASED one", %{scope: scope} do
      for term <- ["wontfix", "OPEN", "Parked", " open "] do
        title = uniq("birth-term")

        result = mutate([create_op(title, task_content(%{"disposition" => term}))], scope)

        assert match?({:error, {:invalid_task_content, %{"disposition" => [_]}}}, result),
               "expected #{inspect(term)} to be refused at birth, got #{inspect(result)}"

        {:error, {:invalid_task_content, %{"disposition" => [message]}}} = result

        assert message =~ "lowercase-canonical vocabulary"
        assert titled_task_ids(title) == []
      end
    end

    test "a COMPLETE birth adjudication is born, and so is a plain open one", %{scope: scope} do
      parked = uniq("birth-parked-ok")

      assert {:ok, _} =
               mutate(
                 [
                   create_op(
                     parked,
                     task_content(%{
                       "disposition" => "parked",
                       "reopen_trigger" => "when the vendor replies"
                     })
                   )
                 ],
                 scope
               )

      assert [_ | _] = titled_task_ids(parked)

      open = uniq("birth-open-ok")
      assert {:ok, _} = mutate([create_op(open, task_content(%{"disposition" => "open"}))], scope)
      assert [_ | _] = titled_task_ids(open)
    end

    test "a createOrReplace on a BRAND-NEW id carrying a hollow park is REFUSED", %{scope: scope} do
      # The wave-24 inversion, from the other create-family door. Same fence:
      # createOrReplace with no existing row lands in create_document with
      # prev_doc == nil, exactly like a plain create.
      id = uniq("birth-cor")

      op = %{
        "createOrReplace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => task_content(%{"disposition" => "parked"})
        }
      }

      assert {:error, {:invalid_task_content, %{"reopen_trigger" => _}}} = mutate([op], scope)
      assert titled_task_ids(id) == []
    end
  end

  describe "birth fence — the unadjudicated birth is ALLOWED and LOGGED" do
    test "a birth with no disposition passes, and says so in the log", %{scope: scope} do
      title = uniq("birth-bare")

      log =
        capture_log(fn ->
          assert {:ok, _} = mutate([create_op(title, task_content(%{}))], scope)
        end)

      assert log =~ "pds birth fence: unadjudicated task birth"
      assert log =~ "bp task stage"
      assert [_ | _] = titled_task_ids(title)
    end
  end

  describe "birth fence — the replication carve-out rides opts, not content" do
    test "a hollow park born with source: :sync is :ok; the SAME content on :api is refused",
         %{scope: scope} do
      # The carve-out transfers verbatim from mutations.ex:
      #   `Keyword.get(opts, :source, :api) != :api -> :ok`
      # — it reads OPTS. `:source` is server-set on every HTTP door, so a
      # request body can never reach a non-:api value. The paired refusal is
      # what makes this a proof rather than a tautology: identical content,
      # different opts, opposite verdicts.
      content = task_content(%{"disposition" => "parked"})

      synced = uniq("birth-sync")
      assert {:ok, _} = mutate([create_op(synced, content)], scope, source: :sync)
      assert [_ | _] = titled_task_ids(synced)

      api = uniq("birth-api")

      assert {:error, {:invalid_task_content, _}} = mutate([create_op(api, content)], scope)
      assert titled_task_ids(api) == []
    end
  end

  # ── ADOPTION: the side door a birth-scoped fence cannot see ────────────────

  describe "adoption-by-reparent" do
    test "reparenting a task that carries NO adjudication into a closure is REFUSED",
         %{scope: scope} do
      epic = uniq("adopt-epic")
      _ = mk_task!(epic, scope, %{"disposition" => "open"})

      # Born OUTSIDE the closure: no parent_id, and (legally) no disposition —
      # exactly the row the birth fence lets through as a warning.
      orphan = uniq("adopt-orphan")
      _ = mk_task!(orphan, scope)

      assert {:error, {:invalid_task_content, %{"parent_id" => [message]}}} =
               mutate([set_patch(orphan, %{"parent_id" => epic})], scope)

      assert message =~ "Reparenting is ADOPTION"
      assert message =~ "bp task stage"

      # The row did not move.
      refute Map.has_key?(content_of(orphan, scope), "parent_id")
    end

    test "the same reparent is ALLOWED once the row carries an adjudication", %{scope: scope} do
      epic = uniq("adopt-epic-ok")
      _ = mk_task!(epic, scope, %{"disposition" => "open"})

      adopted = uniq("adopt-child-ok")
      _ = mk_task!(adopted, scope, %{"disposition" => "open"})

      assert {:ok, _} = mutate([set_patch(adopted, %{"parent_id" => epic})], scope)
      assert content_of(adopted, scope)["parent_id"] == epic
    end

    test "a PRESENT-BUT-MEANINGLESS disposition does not satisfy the adoption guard",
         %{scope: scope} do
      # Mere presence would be a vacuous check: the raw door has no normaliser,
      # so `disposition: "maybe"` is a string that satisfies a presence test and
      # adjudicates nothing. The guard checks the VOCABULARY.
      epic = uniq("adopt-epic-vac")
      _ = mk_task!(epic, scope, %{"disposition" => "open"})

      # Born with the junk term via the exempt replication door, so the row
      # exists in the state the guard has to judge.
      bogus = uniq("adopt-child-vac")

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => bogus,
            "title" => bogus,
            "content" => task_content(%{"disposition" => "maybe"})
          },
          @dataset,
          [source: :sync] ++ scope
        )

      assert {:error, {:invalid_task_content, %{"parent_id" => _}}} =
               mutate([set_patch(bogus, %{"parent_id" => epic})], scope)
    end

    test "a replicated reparent is exempt (a mirror applies verbatim or wedges the batch)",
         %{scope: scope} do
      epic = uniq("adopt-epic-sync")
      _ = mk_task!(epic, scope, %{"disposition" => "open"})

      orphan = uniq("adopt-orphan-sync")
      _ = mk_task!(orphan, scope)

      assert {:ok, _} = mutate([set_patch(orphan, %{"parent_id" => epic})], scope, source: :sync)
      assert content_of(orphan, scope)["parent_id"] == epic
    end

    test "a patch that does NOT touch parent_id is untouched by the guard", %{scope: scope} do
      # The blast radius of this guard is exactly "writes that change parent_id".
      # An ordinary edit to a bare, parentless task must still work.
      plain = uniq("adopt-untouched")
      _ = mk_task!(plain, scope)

      assert {:ok, _} = mutate([set_patch(plain, %{"priority" => 2})], scope)
      assert content_of(plain, scope)["priority"] == 2
    end
  end

  # ── THE BRIDGE: unauthenticated, and it must never 500 ─────────────────────

  describe "the inbound GitHub bridge is born adjudicated, not exempted" do
    setup do
      prior = Application.get_env(:barkpark, @github_config_key)

      Application.put_env(:barkpark, @github_config_key,
        webhook_secret: @webhook_secret,
        webhook_secret_ttl_ms: 0
      )

      Settings.reset_webhook_secret_cache()

      on_exit(fn ->
        Settings.reset_webhook_secret_cache()

        if prior,
          do: Application.put_env(:barkpark, @github_config_key, prior),
          else: Application.delete_env(:barkpark, @github_config_key)
      end)

      :ok
    end

    test "a signed issues.opened delivery is NOT a 500, and the born row carries term + reason",
         %{scope: scope} do
      number = 928_001

      # No `repository` key and no configured repo → the backlink comment
      # short-circuits and this stays fully local (no network).
      body =
        Jason.encode!(%{
          "action" => "opened",
          "issue" => %{
            "number" => number,
            "title" => "Outsider hit a wall",
            "body" => "Reproduction: it just broke.",
            "user" => %{"login" => "outsider"}
          },
          "sender" => %{"login" => "outsider", "type" => "User"}
        })

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "issues")
        |> put_req_header("x-hub-signature-256", Signature.sign(body, @webhook_secret))
        |> post(@webhook_path, body)

      # THE 500 IS PROVEN NOT TO HAPPEN. `Intake.birth/2` falls through
      # `{:error, reason} -> {:error, reason}`, which the controller maps to
      # internal_server_error — and GitHub redelivers a 5xx forever, so a fence
      # that refuses this pipeline is a permanent redelivery storm on an
      # UNAUTHENTICATED path. Assert the status directly, then the envelope.
      refute conn.status == 500
      assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)

      # Born ADJUDICATED: the term AND a reason naming the issue, read back off
      # the persisted row rather than off the attrs we think we sent.
      content = content_of("gh-#{number}", scope)
      assert content["disposition"] == "open"
      assert content["disposition_reason"] =~ "issue ##{number}"
      assert content["disposition_reason"] =~ "@outsider"
      assert get_in(content, ["github", "state"]) == "intake"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp set_patch(doc_id, set), do: %{"patch" => %{"id" => doc_id, "type" => "task", "set" => set}}

  # Id-less creates get a generated doc_id, so a birth is located by its unique
  # title rather than by id.
  defp titled_task_ids(title) do
    Barkpark.Repo.all(
      from(d in Document, where: d.type == "task" and d.title == ^title, select: d.doc_id)
    )
  end
end
