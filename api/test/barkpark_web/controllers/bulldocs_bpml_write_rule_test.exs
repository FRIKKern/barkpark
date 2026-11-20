defmodule BarkparkWeb.BulldocsBpmlWriteRuleTest do
  @moduledoc """
  Two rules a BPML sync shares between the request and the write it runs:

    * the write rule (`WriteGate.may_write?/2`): a token with no seat, on an
      ARMED operator allowlist, that names another workspace syncs into it and
      lands in that workspace and its project. Unarmed, or armed without it,
      the door refuses (403 `workspace_forbidden`) and nothing is written.
      The same rule inside the write's transaction is in
      `saved_check_scope_test.exs`;
    * the reader's view: a Paper in a dataset with no `paper` schema (the
      seeded ones are `production`'s) refuses the BPML pull and the push alike
      (`scope_unresolved`), and the push writes nothing; the JSON source read,
      which is not pushed back, answers its blocks.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, Tenancy, TenancyFixtures}

  @ds "production"

  defp t(v), do: %{"type" => "text", "value" => v}
  defp slug(name), do: "bpml-rule-#{name}-#{System.unique_integer([:positive])}"

  defp blocks(word),
    do: [
      %{"id" => "h", "type" => "heading", "level" => 2, "text" => "Rule #{word}"},
      %{"id" => "p", "type" => "paragraph", "content" => [t("Body #{word}.")]}
    ]

  defp tenant! do
    ws = TenancyFixtures.create_workspace!()
    {:ok, project} = Tenancy.create_project_with_dataset(ws, %{name: "bpml rule #{ws.slug}"})
    %{ws: ws, project: project}
  end

  defp token!(ws_id) do
    raw = "bpml-rule-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bpml rule", @ds, ["admin"], ws_id)
    {raw, token}
  end

  defp arm(ids) do
    prev = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_token_ids, ids)
    on_exit(fn -> Application.put_env(:barkpark, :operator_token_ids, prev) end)
  end

  # BPML for `slug`, printed by the pull of a throwaway `production` Paper.
  defp bpml_for!(slug, word) do
    source = slug("source")

    {:ok, _} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{"slug" => source, "blocks" => blocks(word)})
      )

    resp = get(scoped_conn(), "/papers/#{source}/source", %{"format" => "bpml"})
    assert resp.status == 200, resp.resp_body
    Repo.delete!(Content.get_paper(source))
    String.replace(resp.resp_body, source, slug)
  end

  defp sync(raw, slug, bpml, rev, extra) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/plugins/bulldocs/papers/#{slug}/sync",
      Map.merge(%{"bpml" => bpml, "baseRev" => rev}, extra)
    )
  end

  defp rows(slug) do
    Repo.all(
      from d in Barkpark.Content.Document,
        where: d.type == "paper" and d.doc_id == ^slug,
        select: {d.workspace_id, d.project_id, d.content}
    )
  end

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "a seatless token on the armed operator allowlist syncs into another workspace" do
    b = tenant!()
    {raw, op} = token!(nil)
    named = %{"workspace_id" => b.ws.id, "project_id" => b.project.id}

    for ids <- [[], [elem(token!(nil), 1).id]] do
      arm(ids)
      slug = slug("op-off")
      resp = sync(raw, slug, bpml_for!(slug, "OFF"), "0", named)
      assert json_response(resp, 403)["error"]["code"] == "workspace_forbidden"
      assert rows(slug) == []
    end

    arm([op.id])
    slug = slug("op-armed")
    assert json_response(sync(raw, slug, bpml_for!(slug, "ON"), "0", named), 200)["created"]
    assert [{ws_id, project_id, _content}] = rows(slug)
    assert {ws_id, project_id} == {b.ws.id, b.project.id}
  end

  test "a Paper in a dataset with no paper schema refuses the pull and the push alike" do
    ds = "bpml-rule-noschema"
    LabelFixtures.register_tags!(ds)
    a = tenant!()
    {raw, _token} = token!(a.ws.id)
    slug = slug("ds")

    {:ok, paper} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => blocks("DS"),
          "dataset" => ds,
          "workspace_id" => a.ws.id,
          "project_id" => a.project.id
        })
      )

    assert Content.Papers.reader_schema(paper, "paper", ds, []) == nil

    pull =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/w/#{a.ws.slug}/p/#{a.project.slug}/d/#{ds}/papers/#{slug}/source", %{
        "format" => "bpml"
      })

    pulled = json_response(pull, 422)["error"]
    assert pulled["code"] == "scope_unresolved"

    # The JSON source read is a read, not the working copy: it answers.
    read =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/w/#{a.ws.slug}/p/#{a.project.slug}/d/#{ds}/papers/#{slug}/source")
      |> json_response(200)

    assert read["source"]["kind"] == "blocks"
    assert Enum.map(read["source"]["blocks"], & &1["id"]) == ["h", "p"]
    assert inspect(read["source"]["blocks"]) =~ "Body DS."

    before = rows(slug)
    {:ok, rev} = Content.Papers.op_rev(paper)
    edited = String.replace(bpml_for!(slug, "DS"), "Body DS.", "Edited DS.")
    pushed = json_response(sync(raw, slug, edited, to_string(rev), %{"dataset" => ds}), 422)
    assert Map.take(pushed["error"], ["code", "message", "hint"]) == pulled
    assert rows(slug) == before
  end
end
