defmodule Barkpark.Plugins.Github.MirrorLabelClampTest do
  @moduledoc """
  End-to-end red-before / green-after for charter D16 (task-85ba043a006de6c3).

  The live defect: a claimed task whose 53-char worker id projected a 60-char
  `worker:` label. GitHub rejects a label name > 50 chars with a 422 that fails
  the WHOLE outbound PATCH — witnessed live as `Oban 40404 {:client_error,422}`
  killing the auto close-mirror (the loop only closed via the state-only
  fallback). This drives the full `MirrorJob.reconcile/2` close path against a
  MOCKED GitHub whose PATCH handler faithfully mimics GitHub's ceiling: it 422s
  the moment ANY label name exceeds 50 chars. Before the projection clamp the
  reconcile returns `{:cancel, {:client_error, 422}}`; after it, the PATCH
  carries a ≤50 `worker:` label and the reconcile is `:ok`.

  Sibling of `mirror_job_test.exs` (which this file must NOT edit — slice 2 owns
  it); the Bypass/Auth harness is replicated so this repro stands alone.
  """

  # async: false — Auth is a singleton GenServer and we mutate Application env.
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Github.{Auth, Link, MirrorJob}

  @dataset "production"
  @app_id "123456"
  @installation_id "987654"
  @repo "FRIKKern/barkpark"
  @inst_token "ghs_installation_token_abc123"
  @token_path "/app/installations/#{@installation_id}/access_tokens"

  # The exact live 53-char worker id that produced the 60-char label that 422'd.
  @live_worker "epic-builder-live-proof-one-frikkern-opened-smoke-iss"

  setup do
    Process.flag(:trap_exit, true)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    # Throwaway RSA keypair — NO real GitHub App credentials exist.
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    prior = Application.get_env(:barkpark, Barkpark.Plugins.Github)

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Github,
      app_id: @app_id,
      installation_id: @installation_id,
      private_key: pem,
      repo: @repo,
      api_base: base,
      github_api_base: base
    )

    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.Github, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Github)
      end
    end)

    {:ok, bypass: bypass, base: base, scope: scope}
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

  defp mk_task!(doc_id, content, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => Map.get(content, "title", doc_id),
          "content" => Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content)
        },
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp stub_token(bypass) do
    Bypass.stub(bypass, "POST", @token_path, fn conn ->
      Plug.Conn.resp(conn, 201, Jason.encode!(%{"token" => @inst_token, "expires_in" => 3600}))
    end)
  end

  # The pre-PATCH drift GET — every update-path reconcile reads current state
  # before it PATCHes.
  defp stub_get(bypass, num) do
    Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/#{num}", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{"number" => num, "state" => "open", "title" => "gh-#{num}"})
      )
    end)
  end

  defp read_json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  # A PATCH handler that mimics GitHub's real 50-char label ceiling: any label
  # name > 50 chars → 422 Validation Failed (exactly the live failure); else 200
  # closed. Captures the PATCH body so the test can inspect the labels sent.
  defp stub_patch_enforcing_label_limit(bypass, num, body_ref) do
    Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/#{num}", fn conn ->
      {json, conn} = read_json_body(conn)
      Agent.update(body_ref, fn _ -> json end)

      over_limit =
        (json["labels"] || [])
        |> Enum.any?(fn name -> String.length(name) > 50 end)

      if over_limit do
        Plug.Conn.resp(
          conn,
          422,
          Jason.encode!(%{
            "message" => "Validation Failed",
            "errors" => [%{"resource" => "Label", "code" => "custom", "message" => "too long"}]
          })
        )
      else
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => num, "state" => "closed"}))
      end
    end)
  end

  defp fast, do: [max_retries: 1, retry_delay_ms: 5]

  describe "close-mirror PATCH with a 53-char worker id (D16 live repro)" do
    test "the projected worker label is ≤50 and the close PATCH is :ok (no 422)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      num = 2186

      # A claimed, done task — the exact live shape: worker in content.claim,
      # already mirrored, now closing → the update (close) PATCH path.
      _task =
        mk_task!(
          id,
          %{
            "lifecycle_status" => "done",
            "claim" => %{"worker" => @live_worker},
            "worker" => @live_worker
          },
          scope
        )

      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: num, state: "synced"}, scope)

      stub_get(bypass, num)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)
      stub_patch_enforcing_label_limit(bypass, num, body_ref)

      # GREEN AFTER: the clamp keeps the worker label ≤50 so GitHub accepts the
      # PATCH. RED BEFORE (unclamped): a 60-char label → the mock 422s → reconcile
      # returns {:cancel, {:client_error, 422}} and this assertion fails.
      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      body = Agent.get(body_ref, & &1)
      labels = body["labels"] || []

      # The close still projected a worker label — clamped, not dropped.
      worker_label = Enum.find(labels, &String.starts_with?(&1, "worker:"))
      assert is_binary(worker_label)
      assert String.length(worker_label) <= 50

      # And nothing else in the PATCH can breach the ceiling either.
      for name <- labels do
        assert String.length(name) <= 50
      end

      # The state-only close still landed (the ledger closes GitHub too).
      assert body["state"] == "closed"
      assert body["state_reason"] == "completed"
    end
  end
end
