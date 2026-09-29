defmodule BarkparkWeb.GithubWebhookDedupScopeTest do
  @moduledoc """
  The webhook dedup gate must SCAN THE BACKLOG IT WRITES INTO.

  The webhook pipeline carries no scope plug, so the Intake write resolves its
  tenancy through `Content.WriteScope.resolve_write_scope/1` — which falls back
  to the seeded Default workspace when no `:workspace_id` opt is threaded
  (charter D15: an absent `BARKPARK_GITHUB_INTAKE_WORKSPACE_ID` is a SUPPORTED
  configuration, not an outage). The candidate scan used to read that same key
  RAW and hand `nil` to `Content.Scope.scope_to_workspace/3`, whose nil arm
  fails CLOSED (`where: false`) — so the gate scanned ZERO rows, found no
  look-alike, and every outsider issue was born. A correct-looking green from a
  gate that never ran.

  BOTH ARMS, because one alone cannot tell an inert gate from a gate that ran
  and disagreed: the same signed delivery against the same seeded look-alike,
  once with the intake workspace UNSET and once with it SET.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Settings, Signature}

  @path "/v1/plugins/github/webhook"
  @secret "dedup-scope-webhook-secret-xyz789"
  @config_key Barkpark.Plugins.Github
  @dataset "production"
  @intake_env "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"
  @lookalike_title "Sheets import drops the trailing column on upload"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    prior = Application.get_env(:barkpark, @config_key)
    Application.put_env(:barkpark, @config_key, webhook_secret: @secret, webhook_secret_ttl_ms: 0)
    Settings.reset_webhook_secret_cache()

    prior_env = System.get_env(@intake_env)
    System.delete_env(@intake_env)

    on_exit(fn ->
      Settings.reset_webhook_secret_cache()

      if prior_env,
        do: System.put_env(@intake_env, prior_env),
        else: System.delete_env(@intake_env)

      if prior,
        do: Application.put_env(:barkpark, @config_key, prior),
        else: Application.delete_env(:barkpark, @config_key)
    end)

    %{scope: scope, workspace: ws}
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

  # The look-alike the gate is supposed to find, seeded in the SAME default
  # scope the scope-less webhook write resolves against.
  defp seed_lookalike!(scope) do
    doc_id = "task-dedup-scope-#{System.unique_integer([:positive])}"

    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "description" => "Uploading a sheet loses the last column."
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => @lookalike_title,
          "content" => Map.put(content, "dedup_bypass", true)
        },
        @dataset,
        scope
      )

    doc
  end

  defp opened_body(number) do
    Jason.encode!(%{
      "action" => "opened",
      "issue" => %{
        "number" => number,
        "title" => @lookalike_title,
        "body" => "Uploading a sheet loses the last column."
      },
      "sender" => %{"login" => "outsider", "type" => "User"}
    })
  end

  defp deliver(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "issues")
    |> put_req_header("x-hub-signature-256", Signature.sign(body, @secret))
    |> post(@path, body)
  end

  defp task_rows(number) do
    like = "%gh-#{number}"

    Repo.all(
      from(d in Document, where: d.type == "task" and like(d.doc_id, ^like), select: d.doc_id)
    )
  end

  # Capture what the gate ACTUALLY scanned. The final receipt cannot tell an
  # inert gate from a gate that ran and disagreed; this can.
  defp capture_scan(fun) do
    ref = make_ref()
    parent = self()
    handler = "dedup-scope-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :tasks, :dedup, :scan],
      fn _e, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
      nil
    )

    try do
      result = fun.()

      scans =
        Stream.repeatedly(fn ->
          receive do
            {^ref, m, md} -> {m, md}
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      {result, scans}
    after
      :telemetry.detach(handler)
    end
  end

  describe "the intake dedup gate scans the backlog the webhook write lands in" do
    test "UNSET intake workspace: the seeded look-alike is still seen and the issue is REFUSED",
         %{scope: scope} do
      seed_lookalike!(scope)
      number = 77_301
      refute System.get_env(@intake_env)

      {conn, scans} = capture_scan(fn -> deliver(opened_body(number)) end)

      scanned = scans |> Enum.map(fn {m, _} -> m.candidates end) |> Enum.max(fn -> 0 end)

      assert scanned > 0,
             "THE GATE WENT INERT: the dedup gate scanned #{scanned} candidates " <>
               "(zero-candidate scan) with #{@intake_env} unset, so no look-alike could " <>
               "ever be found — scans=#{inspect(scans)}"

      body = json_response(conn, 202)

      assert match?(%{"refused" => true}, body),
             "expected the look-alike to be refused, got #{inspect(body)}"

      assert task_rows(number) == [],
             "a duplicate row was BORN despite a seeded look-alike"
    end

    test "SET intake workspace: the same delivery is refused (positive control)", %{
      scope: scope,
      workspace: ws
    } do
      seed_lookalike!(scope)
      number = 77_302
      System.put_env(@intake_env, ws.id)

      {conn, scans} = capture_scan(fn -> deliver(opened_body(number)) end)

      scanned = scans |> Enum.map(fn {m, _} -> m.candidates end) |> Enum.max(fn -> 0 end)

      assert scanned > 0,
             "the gate scanned #{scanned} candidates with #{@intake_env} SET — " <>
               "scans=#{inspect(scans)}"

      body = json_response(conn, 202)

      assert match?(%{"refused" => true}, body),
             "expected the look-alike to be refused with the intake workspace set, " <>
               "got #{inspect(body)}"

      assert task_rows(number) == []
    end

    test "a genuinely NEW outsider issue is still born (the gate refuses duplicates, not work)",
         %{scope: scope} do
      seed_lookalike!(scope)
      number = 77_303

      body =
        Jason.encode!(%{
          "action" => "opened",
          "issue" => %{
            "number" => number,
            "title" => "Bokbasen ONIX export omits the contributor biography",
            "body" => "The <Biography> element never appears in the emitted product."
          },
          "sender" => %{"login" => "outsider", "type" => "User"}
        })

      conn = deliver(body)

      assert %{"ingested" => true} = json_response(conn, 200)
      assert task_rows(number) != []
    end
  end
end
