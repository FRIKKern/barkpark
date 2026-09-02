defmodule BarkparkWeb.GithubWebhookIntegrationTest do
  @moduledoc """
  Wave 8 — the inbound webhook proven END-TO-END through the REAL stack.

  Every other github webhook test isolates one layer: the signature plug test
  primes `assigns.raw_body` by hand, and the controller test injects the Intake
  through a seam. NONE of them exercise the actual request edge — the endpoint's
  `Plug.Parsers` + `CacheBodyReader` tee, the router `:github_webhook` pipeline,
  the `GithubWebhookSignature` HMAC gate, the controller dispatch, and the REAL
  `Github.Intake` birth — as one flow. This test closes that gap (the carry
  flagged since wave 3): it POSTs a raw JSON STRING body through the live
  endpoint with a real `X-Hub-Signature-256` computed over those exact bytes.

  Two proofs:

    * a signed `issues.opened` delivery → 2xx AND a real `gh-<num>` task born
      (the genuine Intake, not a stub);
    * a TAMPERED body (signature no longer matches the bytes) → 401 AND zero
      tasks — the fail-closed gate halts before the controller ever runs.

  ## Why a raw string body (not a map)

  `Phoenix.ConnTest.post(conn, path, %{...})` PRE-ENCODES the map and the
  `CacheBodyReader` tee would then capture bytes DIFFERENT from what we signed —
  the signature would verify over the wrong payload and the test would be a lie.
  We hand `post/3` the exact JSON string we signed so the raw-body tee sees the
  signed bytes byte-for-byte.

  ## Hermetic by construction

  No `repository.full_name` in the payload and no `repo` in config → the Intake
  backlink `maybe_comment` short-circuits on a nil repo and NEVER hits GitHub.
  So the whole flow is local: signature (pure HMAC) + Postgres birth, no network.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Settings, Signature}

  @path "/v1/plugins/github/webhook"
  @secret "integration-webhook-secret-abc123"
  @config_key Barkpark.Plugins.Github
  @dataset "production"

  setup do
    # Task schemas must exist in the tenant the flat webhook path writes to. The
    # webhook pipeline carries NO scope plug, so the Intake write falls back to
    # the seeded Default workspace/project (WriteScope) — register there.
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    # Provision ONLY the webhook secret (no repo → the backlink stays local).
    # TTL 0 forces the memoized secret reader to re-resolve every call so no
    # stale persistent_term bleeds across cases; reset the cache in setup AND
    # on_exit (the wave-4 carry: a cached secret flips a 401/200 otherwise).
    prior = Application.get_env(:barkpark, @config_key)
    Application.put_env(:barkpark, @config_key, webhook_secret: @secret, webhook_secret_ttl_ms: 0)
    Settings.reset_webhook_secret_cache()

    on_exit(fn ->
      Settings.reset_webhook_secret_cache()

      if prior,
        do: Application.put_env(:barkpark, @config_key, prior),
        else: Application.delete_env(:barkpark, @config_key)
    end)

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

  # The exact JSON string we sign AND post — no `repository` key, so the Intake
  # backlink never resolves a repo and never touches the network.
  defp opened_body(number) do
    Jason.encode!(%{
      "action" => "opened",
      "issue" => %{
        "number" => number,
        "title" => "Outsider hit a wall",
        "body" => "Reproduction: it just broke."
      },
      "sender" => %{"login" => "outsider", "type" => "User"}
    })
  end

  # Every `gh-<num>` document row (draft or published) for this issue number.
  defp task_rows(number) do
    like = "%gh-#{number}"

    Repo.all(
      from(d in Document,
        where: d.type == "task" and like(d.doc_id, ^like),
        select: d.doc_id
      )
    )
  end

  # POST a raw string body through the live endpoint with the given signature
  # header. The `content-type: application/json` makes Plug.Parsers engage the
  # JSON parser, whose read runs the `CacheBodyReader` tee on this path.
  defp deliver(body, sig_header), do: deliver(body, sig_header, "issues")

  defp deliver(body, sig_header, event) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-hub-signature-256", sig_header)
    |> post(@path, body)
  end

  @gate_text "MERGE GATE: PR merged to origin/main"

  # A task carrying an explicit `merge_gate:true` criterion at index 1, seeded in
  # the SAME default scope the scope-less webhook path resolves against.
  defp mk_gated_task!(scope, doc_id) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [
        %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
        %{"criterion" => @gate_text, "met" => false, "merge_gate" => true}
      ]
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # The exact JSON string we sign AND post for a merged `pull_request` close whose
  # body carries the `Task: <doc_id>` trailer.
  defp merged_pr_body(doc_id, number, sha) do
    Jason.encode!(%{
      "action" => "closed",
      "pull_request" => %{
        "number" => number,
        "merged" => true,
        "merge_commit_sha" => sha,
        "body" => "Some description\n\nTask: #{doc_id}"
      }
    })
  end

  test "a signed issues.opened delivery → 2xx and a real gh-<num> task is born" do
    number = 90_210
    body = opened_body(number)
    sig = Signature.sign(body, @secret)

    conn = deliver(body, sig)

    assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)

    # The REAL Intake ran (no stub) — a born-dark task exists for the issue.
    rows = task_rows(number)
    assert rows != [], "expected a gh-#{number} task to be born through the real Intake"
    assert Enum.any?(rows, &(&1 =~ "gh-#{number}"))

    # And it carries the intake bookkeeping / labels the birth stamps.
    {:ok, doc} = Content.get_document(Content.draft_id("gh-#{number}"), "task", @dataset, [])
    assert doc.content["labels"] == ["src:github", "needs-human"]
    assert get_in(doc.content, ["github", "state"]) == "intake"
  end

  test "a tampered body → 401 and zero tasks (fail-closed HMAC gate halts first)" do
    number = 90_211
    body = opened_body(number)
    # Sign the ORIGINAL bytes, then deliver a DIFFERENT payload — the signature
    # no longer matches, so the gate must 401 before the controller/Intake runs.
    sig = Signature.sign(body, @secret)
    tampered = opened_body(number + 999)

    conn = deliver(tampered, sig)

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    # Neither payload's issue produced a task — the request never reached Intake.
    assert task_rows(number) == []
    assert task_rows(number + 999) == []
  end

  # PDS — the `stamped:` receipt of github_webhook_controller.ex:189 asserted
  # against the STORED ROW, not against a stubbed callee return. Every other
  # webhook controller test injects `merge_events_fun()` through the app-env seam,
  # so it can only prove "given a stub returns tag X, the body says Y" — a mapping.
  # This drives the REAL MergeEvents → Tasks.reconcile_merge_gate → Postgres and
  # asserts the printed sentence AND the row it claims. Neuter the stamp write and
  # the JSON assertion still passes while the Repo assertion reds: that gap IS the
  # differential.
  test "a signed merged pull_request → the stamped: receipt matches the stored row", %{
    scope: scope
  } do
    doc_id = "pds-w36-e2e-#{System.unique_integer([:positive])}"
    task = mk_gated_task!(scope, doc_id)
    assert Enum.at(task.content["acceptance_criteria"], 1)["met"] == false

    body = merged_pr_body(doc_id, 4621, "abc1234def")
    sig = Signature.sign(body, @secret)

    conn = deliver(body, sig, "pull_request")

    # THE RECEIPT — controller line 189, verbatim shape.
    assert %{"ok" => true, "stamped" => true, "task" => ^doc_id, "criteria" => [1]} =
             json_response(conn, 200)

    # THE STORED ROW — the post-condition the receipt asserts.
    reloaded = Repo.get!(Document, task.id)
    gate = Enum.at(reloaded.content["acceptance_criteria"], 1)

    assert gate["met"] == true,
           "receipt said stamped: true but the stored merge_gate criterion is still unmet"

    assert gate["criterion"] == @gate_text
    assert gate["evidence"] =~ "PR #4621"
    assert gate["evidence"] =~ "commit abc1234def"

    # STAMP-ONLY at the wire: the receipt never implies a lifecycle flip.
    assert reloaded.content["lifecycle_status"] == "open"
    assert reloaded.rev != task.rev, "a stamp that changed nothing would leave rev untouched"
  end

  # MARGINAL COST PROBE — the same fixture proves controller line 194's
  # `reconciled: "already_stamped"` receipt against the row it implies (NO second
  # write). A redelivery must not double-stamp: the rev is the post-condition.
  test "a REDELIVERED merged pull_request → reconciled: already_stamped and NO second write", %{
    scope: scope
  } do
    doc_id = "pds-w36-replay-#{System.unique_integer([:positive])}"
    task = mk_gated_task!(scope, doc_id)

    body = merged_pr_body(doc_id, 4622, "beef0001")
    sig = Signature.sign(body, @secret)

    assert %{"ok" => true, "stamped" => true} =
             json_response(deliver(body, sig, "pull_request"), 200)

    after_first = Repo.get!(Document, task.id)

    assert %{"ok" => true, "reconciled" => "already_stamped", "task" => ^doc_id} =
             json_response(deliver(body, sig, "pull_request"), 200)

    after_replay = Repo.get!(Document, task.id)

    assert after_replay.rev == after_first.rev,
           "reconciled: already_stamped claims NO write — the rev moved anyway"

    assert after_replay.content == after_first.content
  end

  # ── PDS w36 crit 3: the {:error, reason} 5xx arm, bought GENUINELY ────────
  #
  # `github_webhook_controller.ex:211-222` maps a merge-reconcile failure to a
  # 500 `merge_reconcile_failed`. Every other webhook test reaches that arm by
  # injecting `:github_webhook_merge_events_fun` and returning `{:error, _}` —
  # a mapping assertion ("given a stub says error, the body says 500"), which
  # proves nothing about whether the real path can produce that error or what
  # the store looks like afterwards. This buys the arm with the race the
  # controller comment actually names: a LOST rev-CAS.
  #
  # `Tasks.reconcile_merge_gate/3` opens a transaction, takes
  # `pg_advisory_xact_lock`, reads the task BY PK, and only then CASes the stamp
  # write on the rev it read (`Internal.fenced_content_write/4`, which answers
  # `:stale` when the CAS matches zero rows). Nothing here is stubbed — the
  # seams stay untouched and the REAL MergeEvents -> Tasks -> Postgres path
  # runs; a repo-query observer bumps the row's rev in the window between that
  # read and that write, on this test's own connection, so the CAS genuinely
  # loses.
  test "a LOST rev-CAS race → 500 merge_reconcile_failed and the gate stays UNMET", %{
    scope: scope
  } do
    doc_id = "pds-w36-cas-#{System.unique_integer([:positive])}"
    task = mk_gated_task!(scope, doc_id)
    assert Enum.at(task.content["acceptance_criteria"], 1)["met"] == false

    body = merged_pr_body(doc_id, 4623, "cafe0002")
    sig = Signature.sign(body, @secret)

    race_rev_after_reconcile_read(task.id)

    conn = deliver(body, sig, "pull_request")

    # THE RECEIPT — controller line 211-222's arm, verbatim shape.
    assert %{"error" => %{"code" => "merge_reconcile_failed"}} = json_response(conn, 500)

    # THE POST-CONDITION the 5xx implies: the reconcile wrote NOTHING. Read the
    # row DIRECTLY by the id this test created (never a whole-table read — many
    # agents share this database), never through a second endpoint.
    reloaded = Repo.get!(Document, task.id)
    gate = Enum.at(reloaded.content["acceptance_criteria"], 1)

    assert gate["met"] == false,
           "the 500 said the reconcile failed, but the stored merge_gate criterion is stamped"

    refute Map.has_key?(gate, "evidence")

    refute Map.has_key?(reloaded.content, "merge_gate_autostamp"),
           "a failed reconcile left an autostamp provenance record behind"

    assert reloaded.content["lifecycle_status"] == "open"
  end

  # ── PDS w36 crit 4: the no-write post-condition, on the WRITE path ────────
  #
  # The replay test above (`reconciled: already_stamped and NO second write`)
  # already asserts `after_replay.rev == after_first.rev`. What wave 36 never
  # exercised is a mutation that reds THAT assertion without also redding the
  # receipt: its recorded mutation perturbed the CLASSIFIER, which flips the
  # printed tag first, so the rev post-condition was carried by the receipt
  # assert and never stood on its own. This case isolates it — it asserts ONLY
  # the store, so a stray write inside `reconcile_merge_gate/3`'s transaction
  # (the write path, not the classification) reds here and nowhere else.
  test "a REDELIVERED merged pull_request writes NOTHING — store-only post-condition", %{
    scope: scope
  } do
    doc_id = "pds-w36-nowrite-#{System.unique_integer([:positive])}"
    task = mk_gated_task!(scope, doc_id)

    body = merged_pr_body(doc_id, 4624, "beef0002")
    sig = Signature.sign(body, @secret)

    _ = deliver(body, sig, "pull_request")
    after_first = Repo.get!(Document, task.id)

    _ = deliver(body, sig, "pull_request")
    after_replay = Repo.get!(Document, task.id)

    # NO receipt is read in this case ON PURPOSE: the tag is the classifier's
    # word for it, and this test exists to make the STORE say it independently.
    assert after_replay.rev == after_first.rev,
           "the replay claimed no write, but the rev moved"

    assert after_replay.updated_at == after_first.updated_at,
           "the replay claimed no write, but the row was touched"

    assert after_replay.content == after_first.content
  end

  # Attach a one-shot repo-query observer that reproduces a GENUINE rev-CAS race
  # INSIDE `Tasks.reconcile_merge_gate/3`'s own transaction.
  #
  # The reconcile's query order is: `pg_advisory_xact_lock` → the by-PK
  # `documents` SELECT → the CAS UPDATE fenced on the rev that SELECT returned.
  # Seeing the advisory lock ARMS the observer; the very next `documents` SELECT
  # is that by-PK read, and the instant it completes we bump the row's rev on
  # the SAME process (so the write lands inside the reconcile's transaction and
  # its own CAS then matches zero rows). One-shot and pid-fenced, so it cannot
  # reach another test's queries.
  defp race_rev_after_reconcile_read(task_id) do
    owner = self()
    handler_id = {__MODULE__, :rev_race, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == owner do
          query = to_string(meta[:query] || "")

          cond do
            query =~ "pg_advisory_xact_lock" ->
              Process.put(handler_id, :armed)

            Process.get(handler_id) == :armed and String.starts_with?(query, "SELECT") and
                query =~ ~s("documents") ->
              # Mark FIRST: this update re-enters the handler, and a second
              # bump would be a different (and untrue) fixture.
              Process.put(handler_id, :fired)

              {1, _} =
                Repo.update_all(
                  from(d in Document, where: d.id == ^task_id),
                  set: [rev: "raced-#{System.unique_integer([:positive])}"]
                )

            true ->
              :ok
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end
end
