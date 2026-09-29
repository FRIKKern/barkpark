defmodule BarkparkWeb.MutateTaskCreateMissingFieldTest do
  @moduledoc """
  cch-w29-bl-raw-task-create-without-brief-500s — a raw task create through
  `POST /v1/data/mutate/:dataset` that omits a required field is answered with
  a status that NAMES the field, never a 500 `internal_error / "unknown error"`
  carrying retry advice.

  The row (filed 2026-08-03) measured two 500s on a briefless create and a 200
  on the same body with a brief, and said the crash site was unproven. This
  file is the reproduction, run on the test env, not on the live ledger:

    * create WITHOUT a brief            -> 200 (a draft; a brief is not a
                                           create-time requirement at all)
    * create + publish WITHOUT a brief  -> 409 naming `content.brief`
    * create WITHOUT a title            -> 409 naming the title
    * create WITHOUT kind/lifecycle     -> 422 naming both fields

  None of them is a 500, on origin/main or on the filing-date tree (main at
  683c2f00a, 2026-08-03). On that older tree the briefless create+publish
  answered 200 — the publish wall was registered but inert on this door until
  #19303 (e58d8bbcd) — so the publish arm below is RED against those bytes.

  Every arm asserts a status that is neither 2xx-by-accident nor 5xx, and a
  message that carries the missing field's name, so a regression to a bare
  `unknown error` fails here by name.

  SHARED TEST DATABASE: no assertion counts rows or reads a table; each arm
  writes under a unique id and reads back only that id's response.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @token "barkpark-test-mutate-create-missing-field"
  @dataset "test"

  setup do
    {:ok, _} =
      Barkpark.Auth.create_token(
        @token,
        "test-mutate-create-missing-field",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp mutate(mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Clears every other wall on the create/publish path (label spine, tag
  # registry, criteria fence) and carries NO brief.
  defp briefless_content do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "priority" => 2,
      "description" =>
        "A deliberately long description so the label spine is satisfied and " <>
          "the only variable across these arms is the field each one omits.",
      "acceptance_criteria" => [%{"criterion" => "the missing field is named", "met" => false}]
    }
    |> Map.merge(LabelFixtures.weighted_labels())
  end

  defp task(id), do: %{"_id" => id, "_type" => "task", "title" => "probe #{id}"}

  defp error_message(resp) do
    body = Jason.decode!(resp.resp_body)
    %{"code" => code, "message" => message} = body["error"]
    {code, message, body["error"]["details"]}
  end

  test "a create WITHOUT a brief is a 200 draft, not a 500" do
    id = uniq("briefless-create")

    resp = mutate([%{"create" => Map.put(task(id), "content", briefless_content())}])

    assert resp.status == 200, "got #{resp.status}: #{resp.resp_body}"

    [result] = Jason.decode!(resp.resp_body)["results"]
    assert result["id"] == "drafts." <> id
    assert result["document"]["_draft"] == true
    refute Map.has_key?(result["document"], "brief")
  end

  test "a create + publish WITHOUT a brief is a 409 naming content.brief" do
    id = uniq("briefless-publish")

    resp =
      mutate([
        %{"create" => Map.put(task(id), "content", briefless_content())},
        %{"publish" => %{"id" => id, "type" => "task"}}
      ])

    assert resp.status == 409, "got #{resp.status}: #{resp.resp_body}"
    {code, message, _} = error_message(resp)
    assert code == "halted"
    assert message =~ "content.brief"
    refute message =~ "unknown error"
  end

  test "a create WITHOUT a title is a 409 naming the title" do
    id = uniq("titleless-create")

    resp =
      mutate([
        %{"create" => task(id) |> Map.delete("title") |> Map.put("content", briefless_content())}
      ])

    assert resp.status == 409, "got #{resp.status}: #{resp.resp_body}"
    {code, message, _} = error_message(resp)
    assert code == "halted"
    assert message =~ "task title is required"
    refute message =~ "unknown error"
  end

  test "a create WITHOUT kind and lifecycle_status is a 422 naming both" do
    id = uniq("contentless-create")

    resp = mutate([%{"create" => task(id)}])

    assert resp.status == 422, "got #{resp.status}: #{resp.resp_body}"
    {code, _message, details} = error_message(resp)
    assert code == "validation_failed"
    assert Map.has_key?(details, "kind")
    assert Map.has_key?(details, "lifecycle_status")
  end
end
