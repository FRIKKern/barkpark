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
  defp deliver(body, sig_header) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "issues")
    |> put_req_header("x-hub-signature-256", sig_header)
    |> post(@path, body)
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
end
