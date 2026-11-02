defmodule BarkparkWeb.BulldocsPortableDocRatchetTest do
  @moduledoc """
  The PortableDoc ratchet on every paper write door an agent uses (R4.5):
  ingest, one op, an op batch, a proposal, and the validate dry run.

    * report-only (the default): the write lands and its reply carries a
      `portable_doc_invalid` warning listing the errors it added;
    * refusing (`:portable_doc_refuse_new_errors`): the write is a 409 `halted`
      naming the added error, and the paper is unchanged;
    * a paper that is already broken is never blocked by its old errors.

  The added error is a heading at level 9 (`value_not_allowed`), which no other
  paper gate refuses. Synthetic papers only.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Warnings
  alias Barkpark.LabelFixtures

  @token "barkpark-test-ingest-token"
  @dataset "production"
  @papers "/v1/plugins/bulldocs/papers"

  setup do
    previous = Application.get_env(:barkpark, :portable_doc_refuse_new_errors)
    on_exit(fn -> Application.put_env(:barkpark, :portable_doc_refuse_new_errors, previous) end)
    Application.delete_env(:barkpark, :portable_doc_refuse_new_errors)
    :ok
  end

  defp refusing!, do: Application.put_env(:barkpark, :portable_doc_refuse_new_errors, true)

  defp para(id),
    do: %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Prose #{id}."}]
    }

  defp bad_heading(id),
    do: %{"id" => id, "type" => "heading", "level" => 9, "text" => "Heading #{id}"}

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp post_json(path, body, headers \\ []) do
    headers
    |> Enum.reduce(
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json"),
      fn {k, v}, conn -> put_req_header(conn, k, v) end
    )
    |> post(path, body)
  end

  defp seed!(slug, blocks) do
    {:ok, _} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{"slug" => slug, "dataset" => @dataset, "blocks" => blocks})
      )

    slug
  end

  defp stored(slug),
    do: Content.get_paper(slug, @dataset).content["blocks"] |> Enum.map(& &1["id"])

  defp ingest(slug, blocks),
    do:
      post_json(
        @papers,
        LabelFixtures.paper_attrs(%{"slug" => slug, "dataset" => @dataset, "blocks" => blocks})
      )

  defp op(slug, op), do: post_json("#{@papers}/#{slug}/ops", op)
  defp batch(slug, ops), do: post_json("#{@papers}/#{slug}/ops", %{"ops" => ops})
  defp append(block), do: %{"op" => "append-block", "block" => block}

  defp dry_run(slug, blocks),
    do:
      post_json(
        "#{@papers}/validate",
        LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => blocks})
      )

  defp propose(slug, block) do
    source = seed!(slug("ratchet-source"), [para("src")])

    post_json("#{@papers}/#{slug}/proposals", %{
      "ops" => [append(block)],
      "source" => %{"doc_id" => source, "agent" => "ratchet-test"}
    })
  end

  defp portable_doc_warning(body),
    do: Enum.find(body["warnings"] || [], &(&1["code"] == "portable_doc_invalid"))

  defp assert_reported(conn, path) do
    body = json_response(conn, 200)
    warning = portable_doc_warning(body)

    assert %{
             "severity" => "warning",
             "violations" => [%{"code" => "value_not_allowed", "path" => ^path}]
           } = warning

    assert warning["message"] =~ "adds 1 PortableDoc error(s): value_not_allowed at #{path}"
    body
  end

  defp assert_refused(conn, path) do
    assert %{"code" => "halted", "message" => message} =
             json_response(conn, 409)["error"] || json_response(conn, 409)

    assert message =~ "adds 1 PortableDoc error(s): value_not_allowed at #{path}"
  end

  describe "report-only (the default)" do
    test "one op lands and its reply carries the warning" do
      s = seed!(slug("ratchet-op"), [para("a")])
      assert_reported(op(s, append(bad_heading("h"))), "/blocks/1/level")
      assert "h" in stored(s)
    end

    test "an op batch lands and its reply carries the warning" do
      s = seed!(slug("ratchet-batch"), [para("a")])
      assert_reported(batch(s, [append(para("b")), append(bad_heading("h"))]), "/blocks/2/level")
      assert "h" in stored(s)
    end

    test "an ingest lands and its reply carries the warning" do
      s = seed!(slug("ratchet-ingest"), [para("a")])
      assert_reported(ingest(s, [para("a"), bad_heading("h")]), "/blocks/1/level")
      assert "h" in stored(s)
    end

    test "a proposal lands on the draft and its reply carries the warning" do
      s = seed!(slug("ratchet-propose"), [para("a")])
      body = assert_reported(propose(s, bad_heading("h")), "/blocks/1/level")
      assert body["applied_block_ids"] == ["h"]
    end

    test "the dry run stays valid and carries the same warning" do
      s = slug("ratchet-dry")
      body = assert_reported(dry_run(s, [para("a"), bad_heading("h")]), "/blocks/1/level")
      assert body["valid"] == true
    end

    test "a clean write carries no PortableDoc warning" do
      s = seed!(slug("ratchet-clean"), [para("a")])
      assert portable_doc_warning(json_response(op(s, append(para("b"))), 200)) == nil
    end
  end

  describe "refusing" do
    test "one op is a 409 halted and the paper is unchanged" do
      s = seed!(slug("ratchet-op-refused"), [para("a")])
      refusing!()
      assert_refused(op(s, append(bad_heading("h"))), "/blocks/1/level")
      assert stored(s) == ["a"]
    end

    test "an op batch is a 409 halted and the paper is unchanged" do
      s = seed!(slug("ratchet-batch-refused"), [para("a")])
      refusing!()
      assert_refused(batch(s, [append(para("b")), append(bad_heading("h"))]), "/blocks/2/level")
      assert stored(s) == ["a"]
    end

    test "an ingest is a 409 halted and the paper is unchanged" do
      s = seed!(slug("ratchet-ingest-refused"), [para("a")])
      refusing!()
      assert_refused(ingest(s, [para("a"), bad_heading("h")]), "/blocks/1/level")
      assert stored(s) == ["a"]
    end

    test "a proposal is a 409 halted and no draft block is written" do
      s = seed!(slug("ratchet-propose-refused"), [para("a")])
      refusing!()
      assert_refused(propose(s, bad_heading("h")), "/blocks/1/level")

      draft = Content.get_paper("drafts." <> s, @dataset)
      assert draft == nil or not Enum.any?(draft.content["blocks"], &(&1["id"] == "h"))
    end

    test "the dry run names the added error as a violation" do
      refusing!()

      body =
        json_response(dry_run(slug("ratchet-dry-refused"), [para("a"), bad_heading("h")]), 200)

      assert body["valid"] == false

      assert %{"path" => "/blocks/1/level", "message" => "value_not_allowed at /blocks/1/level"} =
               Enum.find(body["violations"], &(&1["code"] == "portable_doc-value_not_allowed"))
    end
  end

  describe "a paper that is already broken" do
    setup do
      %{slug: seed!(slug("ratchet-broken"), [para("a"), bad_heading("old")])}
    end

    test "is never blocked by its old errors, on any door", %{slug: s} do
      refusing!()

      assert %{"ok" => true} = json_response(op(s, append(para("b"))), 200)
      assert %{"ok" => true} = json_response(batch(s, [append(para("c"))]), 200)

      assert %{"ok" => true} =
               json_response(ingest(s, [para("z"), para("a"), bad_heading("old")]), 200)

      assert %{"ok" => true} = json_response(propose(s, para("p")), 200)

      body = json_response(dry_run(s, [para("y"), para("a"), bad_heading("old")]), 200)
      refute Enum.any?(body["violations"], &String.starts_with?(&1["code"], "portable_doc"))
      assert stored(s) == ["z", "a", "old"]
    end

    test "the dry run normalizes as ingest does: an id-less broken block keeps its minted place" do
      idless = %{"type" => "heading", "level" => 9, "text" => "Id-less"}
      s = seed!(slug("ratchet-idless"), [para("a"), idless])
      refusing!()

      body = json_response(dry_run(s, [para("a"), idless]), 200)
      refute Enum.any?(body["violations"], &String.starts_with?(&1["code"], "portable_doc"))
    end

    test "an item added above a broken list item is not refused (patch-block)" do
      item = fn text -> %{"content" => [%{"type" => "text", "value" => text}]} end
      broken = Map.put(item.("b"), "checked", "yes")

      list = fn items ->
        %{"id" => "l", "type" => "list", "ordered" => false, "items" => items}
      end

      s = seed!(slug("ratchet-list"), [para("a"), list.([item.("a"), broken])])
      refusing!()

      patch = %{
        "op" => "patch-block",
        "id" => "l",
        "patch" => %{"items" => [item.("new"), item.("a"), broken]}
      }

      assert %{"ok" => true} = json_response(op(s, patch), 200)
    end

    test "still refuses an error the write adds; an op or batch counts only the old errors in what it touched",
         %{slug: s} do
      refusing!()
      conn = op(s, append(bad_heading("new")))
      assert_refused(conn, "/blocks/2/level")
      assert json_response(conn, 409) |> inspect() =~ "it keeps 0 old error(s)"

      conn = batch(s, [append(bad_heading("new"))])
      assert_refused(conn, "/blocks/2/level")
      assert json_response(conn, 409) |> inspect() =~ "it keeps 0 old error(s)"

      conn = ingest(s, [para("a"), bad_heading("old"), bad_heading("new")])
      assert_refused(conn, "/blocks/2/level")
      assert json_response(conn, 409) |> inspect() =~ "it keeps 1 old error(s)"
    end
  end

  describe "the dry run beside the other gates" do
    defp untagged(slug, blocks),
      do: LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => blocks}) |> Map.delete("tags")

    test "report-only: another gate's violation still makes it invalid" do
      body =
        json_response(
          post_json("#{@papers}/validate", untagged(slug("ratchet-wall"), [bad_heading("h")])),
          200
        )

      assert body["valid"] == false
      assert [_ | _] = body["violations"]
      assert %{"violations" => [_]} = portable_doc_warning(body)
    end

    test "refusing: the added error joins the other gates' violations" do
      refusing!()

      body =
        json_response(
          post_json("#{@papers}/validate", untagged(slug("ratchet-wall"), [bad_heading("h")])),
          200
        )

      codes = Enum.map(body["violations"], & &1["code"])
      assert "portable_doc-value_not_allowed" in codes
      assert Enum.any?(codes, &(not String.starts_with?(&1, "portable_doc")))
    end

    test "reads the stored paper in the dataset the body names" do
      s = slug("ratchet-dataset")
      dataset = "r45-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            "slug" => s,
            "dataset" => dataset,
            "blocks" => [para("a"), bad_heading("old")]
          })
        )

      body =
        json_response(
          post_json(
            "#{@papers}/validate",
            LabelFixtures.paper_attrs(%{
              "slug" => s,
              "dataset" => dataset,
              "blocks" => [para("a"), bad_heading("old")]
            })
          ),
          200
        )

      assert portable_doc_warning(body) == nil
    end

    test "reads the stored paper in the project the request names, not a sibling project" do
      ws = create_workspace!()
      p1 = create_project!(ws, "p1")
      p2 = create_project!(ws, "p2")
      s = slug("ratchet-project")

      {:ok, _} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            "slug" => s,
            "dataset" => @dataset,
            "workspace_id" => ws.id,
            "project_id" => p1.id,
            "blocks" => [para("a"), bad_heading("old")]
          })
        )

      dry = fn project ->
        "#{@papers}/validate"
        |> post_json(
          LabelFixtures.paper_attrs(%{"slug" => s, "blocks" => [para("a"), bad_heading("old")]}),
          [
            {"x-barkpark-workspace", ws.slug},
            {"x-barkpark-project", project.slug}
          ]
        )
        |> json_response(200)
        |> portable_doc_warning()
      end

      assert dry.(p1) == nil
      assert %{"violations" => [_], "existing" => []} = dry.(p2)
    end
  end

  describe "a dry run whose write scope is refused" do
    test "is compared with no paper, never the Default workspace's" do
      ws_a = create_workspace!()
      create_project!(ws_a, "default")
      ws_b = create_workspace!()
      create_project!(ws_b, "default")
      raw = "ratchet-scope-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(
          raw,
          "ratchet-a",
          @dataset,
          ["read", "write", "admin"],
          ws_a.id
        )

      s = seed!(slug("ratchet-scope"), [para("a"), bad_heading("old")])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-barkpark-workspace", ws_b.slug)
        |> post(
          "#{@papers}/validate",
          LabelFixtures.paper_attrs(%{"slug" => s, "blocks" => [para("a"), bad_heading("old")]})
        )

      assert %{"violations" => [%{"path" => "/blocks/1/level"}], "existing" => []} =
               portable_doc_warning(json_response(conn, 200))
    end
  end

  describe "a rev-less op that loses its race" do
    test "reports the warning once, from the retry" do
      s = seed!(slug("ratchet-race"), [para("a")])
      parent = self()
      ref = make_ref()

      racer = fn ->
        unless Process.get(ref) do
          Process.put(ref, true)
          send(parent, :racer_ran)
          {:ok, _} = Content.apply_paper_block_op(s, append(para("b")), @dataset)
        end
      end

      Warnings.reset()

      assert {:ok, _} =
               Content.apply_paper_block_op(s, append(bad_heading("h")), @dataset,
                 before_fenced_write: racer
               )

      assert_received :racer_ran

      assert [%{code: "portable_doc_invalid", violations: [%{path: "/blocks/2/level"}]}] =
               Warnings.drain()
    end
  end
end
