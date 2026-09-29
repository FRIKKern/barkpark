defmodule BarkparkWeb.MutateTaskBriefGateTest do
  @moduledoc """
  task-c1f155da34d3338f — the Tasks plugin's `before_publish` brief wall, driven
  through THE REAL DOOR.

  The gate (`Barkpark.Plugins.Tasks.portable_brief_gate/1`) was already green in
  isolation: every existing test hands it a plain string-keyed map, which is the
  shape `:before_save` fires with. `Content.Lifecycle.publish_after_gate/5` fires
  `:before_publish` with `doc: draft` — a `%Barkpark.Content.Document{}` STRUCT,
  whose keys are atoms — so the gate's `%{doc: %{"type" => "task"}}` head never
  matched and the catch-all clause answered `:ok` for every publish that ever
  reached it. Measured live on guerrilla 2026-09-18: a briefless task and a task
  whose brief carries a bogus block type BOTH published 200.

  So this file refuses to call the plugin function. Every arm is a
  `POST /v1/data/mutate/test` create+publish pair, and the assertion is the HTTP
  status the operator sees:

    * NO brief            -> 409, message names `content.brief`
    * bogus block type    -> 409, message names the offending type
    * well-formed brief   -> 200 (THE CONTROL — the fix must not refuse everything)

  Revert the head-clause fix in `plugins/tasks.ex` and the first two arms go
  green-as-200, which is exactly the defect; the control keeps them honest.

  ## The second arm: GRANDFATHERING

  The wall is scoped to a task ENTERING the published corpus. A row that is
  already published carrying no brief must keep publishing — 3 of 20 rows
  sampled on the live instance are exactly that, and making them
  un-republishable would strand the mutate publish op and the GitHub
  draft-twin collapse on every legacy task.

  The grandfather arm seeds such a row HONESTLY, without touching the Repo and
  without disarming the plugin: it first-publishes with a well-formed brief
  (the only way in), then patches the draft to DROP the brief and re-publishes.
  Publish copies draft content wholesale, so after that second call the
  published row genuinely carries no brief — and a THIRD publish, from a row
  that was already published briefless, proves the grandfathering rather than
  merely the transition. Remove the `published_doc` branch from the gate and
  both of those re-publishes red 409.

  `scoped_conn/0` (never a bare `build_conn/0`) because several requests per test
  run against an ip-keyed limiter.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @token "barkpark-test-mutate-brief-gate"
  @dataset "test"

  setup do
    {:ok, _} =
      Barkpark.Auth.create_token(
        @token,
        "test-mutate-brief-gate",
        "test",
        [
          "read",
          "write",
          "admin"
        ],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    register_task_schemas!()
    LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp register_task_schemas! do
    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    :ok
  end

  defp authed do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate(mutations) do
    post(authed(), "/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A task content that clears every OTHER wall on the publish path (label
  # spine, tag registry, the acceptance_criteria fence) so the ONLY variable
  # across the three arms is `content.brief`.
  defp task_content(brief) do
    base =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "priority" => 2,
        "description" =>
          "A deliberately long description so the label spine is satisfied and the " <>
            "only thing separating these three arms is the brief the task carries.",
        "acceptance_criteria" => [
          %{"criterion" => "the brief wall fires on the mutate door", "met" => false}
        ]
      }
      |> Map.merge(LabelFixtures.weighted_labels())

    case brief do
      :none -> base
      brief -> Map.put(base, "brief", brief)
    end
  end

  # create (draft) + publish, in one mutate envelope, exactly as the live probe
  # ran it. Returns the publish response.
  defp create_and_publish(id, brief) do
    mutate([
      %{
        "create" => %{
          "_id" => id,
          "_type" => "task",
          "title" => "brief gate #{id}",
          "content" => task_content(brief)
        }
      },
      %{"publish" => %{"id" => id, "type" => "task"}}
    ])
  end

  # createOrReplace the DRAFT with the given content, then publish it. The draft
  # write is a plain content edit (only the PUBLISH may refuse), so this is the
  # re-publish an operator issues after editing a live task.
  defp replace_draft_and_publish(id, brief) do
    mutate([
      %{
        "createOrReplace" => %{
          "_id" => "drafts.#{id}",
          "_type" => "task",
          "title" => "brief gate #{id}",
          "content" => task_content(brief)
        }
      },
      %{"publish" => %{"id" => id, "type" => "task"}}
    ])
  end

  defp well_formed_brief do
    %{
      "version" => 1,
      "blocks" => [
        %{"id" => "purpose", "type" => "heading", "level" => 2, "text" => "Purpose"},
        %{
          "id" => "purpose-copy",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "What this task is for."}]
        }
      ]
    }
  end

  describe "POST /v1/data/mutate/:dataset publish of a type:task" do
    test "ARM A — a task with NO brief is REFUSED with a 409 naming content.brief" do
      resp = create_and_publish(uniq("brief-gate-none"), :none)

      assert resp.status == 409,
             "a briefless task must not publish through the mutate door; got " <>
               "#{resp.status}: #{resp.resp_body}"

      body = Jason.decode!(resp.resp_body)
      message = body["error"]["message"] || ""

      assert message =~ "content.brief",
             "the refusal must NAME the field; got: #{inspect(message)}"
    end

    test "ARM B — a brief carrying a bogus block type is REFUSED with a 409 naming it" do
      brief = %{"version" => 1, "blocks" => [%{"type" => "totally-bogus-block"}]}

      resp = create_and_publish(uniq("brief-gate-bogus"), brief)

      assert resp.status == 409,
             "a bogus-block brief must not publish through the mutate door; got " <>
               "#{resp.status}: #{resp.resp_body}"

      body = Jason.decode!(resp.resp_body)
      message = body["error"]["message"] || ""

      assert message =~ "totally-bogus-block",
             "the refusal must NAME the offending block type; got: #{inspect(message)}"
    end

    test "CONTROL — a well-formed PortableDoc brief still publishes 200" do
      id = uniq("brief-gate-ok")
      resp = create_and_publish(id, well_formed_brief())

      assert resp.status == 200,
             "the fix must not refuse a well-formed brief; got #{resp.status}: #{resp.resp_body}"

      read =
        authed()
        |> get("/v1/data/doc/#{@dataset}/task/#{id}")
        |> json_response(200)

      assert read["result"]["_draft"] == false
    end

    test "GRANDFATHER — an already-published task re-publishes with NO brief at all" do
      id = uniq("brief-gate-grandfather")

      # (1) Birth, through the only door a birth has: a well-formed brief.
      assert %{status: 200} = create_and_publish(id, well_formed_brief())

      # (2) The brief is DROPPED and the task re-published. The gate is scoped
      #     to first publish, so this must not be refused — and because publish
      #     copies draft content wholesale, the published row now carries no
      #     brief at all.
      resp = replace_draft_and_publish(id, :none)

      assert resp.status == 200,
             "a re-publish must not be gated — the wall is scoped to first publish; got " <>
               "#{resp.status}: #{resp.resp_body}"

      read =
        authed()
        |> get("/v1/data/doc/#{@dataset}/task/#{id}")
        |> json_response(200)

      assert read["result"]["_draft"] == false

      refute Map.has_key?(read["result"], "brief"),
             "the published row must now genuinely carry no brief, or the arm below " <>
               "proves nothing: #{inspect(Map.keys(read["result"]))}"

      # (3) THE ARM THAT MATTERS: the incumbent is now a published, BRIEFLESS
      #     row — the exact live shape — and it still publishes.
      assert %{status: 200} = replace_draft_and_publish(id, :none)
    end

    test "GRANDFATHER BOUNDARY — a malformed brief on a re-publish is NOT refused" do
      id = uniq("brief-gate-boundary")

      assert %{status: 200} = create_and_publish(id, well_formed_brief())

      # Stated so the boundary is a pinned fact and not a reader's inference:
      # the gate does not fire on a re-publish AT ALL, so a bogus block type
      # that would be a 409 at birth passes here. Shape validation on a
      # re-publish belongs to Tasks.Validation's 422 layer, not to this wall.
      resp =
        replace_draft_and_publish(id, %{
          "version" => 1,
          "blocks" => [%{"type" => "totally-bogus-block"}]
        })

      assert resp.status == 200,
             "the scoping is literal: a re-publish is not gated; got " <>
               "#{resp.status}: #{resp.resp_body}"
    end
  end
end
