defmodule BarkparkWeb.PortableDocRatchetDoorsTest do
  @moduledoc """
  The PortableDoc ratchet (R4.5) on the block-doc writes #25060 left out:
  session upsert, session ops, document ops (one op and a batch), block-editor
  field ops, a paper through `/v1/data/mutate`, and a plan paper.

    * report-only (the default): the write lands and its reply carries a
      `portable_doc_invalid` warning naming the error it added;
    * refusing (`:portable_doc_refuse_new_errors`): a 409 `halted` naming the
      added error, and nothing is written;
    * an error the doc already had never blocks a write.

  The added error is a heading at level 9 (`value_not_allowed`); in a field,
  whose vocabulary refuses that heading first, it is a paragraph whose
  `content` is a string (`wrong_field_type`). Synthetic docs only.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures, TenancyFixtures}
  alias Barkpark.Content.Warnings
  alias Barkpark.PortableDoc.Validate
  alias Barkpark.StudioChat.PlanPapers

  defmodule LoseRaceOnce do
    @moduledoc false
    import Ecto.Query

    def lifecycle_hooks, do: %{before_save: [&__MODULE__.bump/1]}

    def bump(%{doc: %{"doc_id" => doc_id}}) do
      if Process.get(__MODULE__) == doc_id do
        Process.put(__MODULE__, :lost)

        Barkpark.Repo.update_all(
          from(d in Barkpark.Content.Document, where: d.doc_id == ^doc_id),
          set: [rev: "concurrent-" <> Integer.to_string(System.unique_integer([:positive]))]
        )
      end

      :ok
    end

    def bump(_payload), do: :ok
  end

  @ingest_token "barkpark-test-ingest-token"
  @sessions "/v1/plugins/bulldocs/sessions"

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

  defp append(block), do: %{"op" => "append-block", "block" => block}
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp send_json(path, token, body) do
    Warnings.restore(nil)

    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp assert_reported(conn, code, path) do
    body = json_response(conn, 200)
    warning = Enum.find(body["warnings"] || [], &(&1["code"] == "portable_doc_invalid"))

    assert %{"severity" => "warning", "violations" => [%{"code" => ^code, "path" => ^path}]} =
             warning

    assert warning["message"] =~ "adds 1 PortableDoc error(s): #{code} at #{path}"
    body
  end

  defp assert_clean(conn) do
    body = json_response(conn, 200)
    refute Enum.any?(body["warnings"] || [], &(&1["code"] == "portable_doc_invalid"))
    body
  end

  defp assert_refused(conn, code, path) do
    body = json_response(conn, 409)
    error = body["error"] || body
    assert error["code"] == "halted"
    assert error["message"] =~ "adds 1 PortableDoc error(s): #{code} at #{path}"
  end

  describe "session upsert (POST /v1/plugins/bulldocs/sessions)" do
    defp upsert_session(slug, blocks),
      do:
        send_json(@sessions, @ingest_token, %{
          "slug" => slug,
          "title" => "S",
          "status" => "open",
          "blocks" => blocks
        })

    defp session_blocks(slug),
      do: Content.get_blocks_doc(slug, "session", "production").content["blocks"]

    test "report-only: the session lands and the reply carries the warning" do
      slug = unique("ratchet-session")

      assert_reported(
        upsert_session(slug, [para("a"), bad_heading("h")]),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert Enum.map(session_blocks(slug), & &1["id"]) == ["a", "h"]
    end

    test "refusing: the session upsert is a 409 and the stored blocks stay" do
      slug = unique("ratchet-session")
      assert_clean(upsert_session(slug, [para("a")]))
      refusing!()

      assert_refused(
        upsert_session(slug, [para("a"), bad_heading("h")]),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert Enum.map(session_blocks(slug), & &1["id"]) == ["a"]
    end

    test "refusing: a session that already has the error still saves" do
      slug = unique("ratchet-session")
      upsert_session(slug, [bad_heading("h")])
      refusing!()
      assert_clean(upsert_session(slug, [bad_heading("h"), para("b")]))
      assert Enum.map(session_blocks(slug), & &1["id"]) == ["h", "b"]
    end

    test "a metadata-only update carries no blocks and is never checked" do
      slug = unique("ratchet-session")
      upsert_session(slug, [bad_heading("h")])
      refusing!()

      assert_clean(
        send_json(@sessions, @ingest_token, %{"slug" => slug, "title" => "S", "status" => "done"})
      )
    end
  end

  describe "session ops (POST /v1/plugins/bulldocs/sessions/:slug/ops)" do
    defp seed_session(blocks) do
      slug = unique("ratchet-session-op")
      upsert_session(slug, blocks)
      slug
    end

    defp session_op(slug, op), do: send_json("#{@sessions}/#{slug}/ops", @ingest_token, op)

    defp session_draft_ids(slug) do
      case Content.get_document("drafts." <> slug, "session", "production") do
        {:ok, draft} -> Enum.map(draft.content["blocks"], & &1["id"])
        _ -> nil
      end
    end

    test "report-only: the op lands on the draft twin and the reply carries the warning" do
      slug = seed_session([para("a")])

      body =
        assert_reported(
          session_op(slug, append(bad_heading("h"))),
          "value_not_allowed",
          "/blocks/1/level"
        )

      assert body["written_doc_id"] == "drafts." <> slug
      assert session_draft_ids(slug) == ["a", "h"]
    end

    test "refusing: the op is a 409 and no draft is written" do
      slug = seed_session([para("a")])
      refusing!()

      assert_refused(
        session_op(slug, append(bad_heading("h"))),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert session_draft_ids(slug) == nil
    end

    test "refusing: an op beside an old error still applies" do
      slug = seed_session([bad_heading("h")])
      refusing!()
      assert_clean(session_op(slug, append(para("b"))))
      assert session_draft_ids(slug) == ["h", "b"]
    end
  end

  describe "document ops (POST /v1/data/doc/:dataset/:type/:doc_id/ops)" do
    setup do
      ws = TenancyFixtures.default_workspace_id!()
      Auth.create_token("ratchet-ops-token", "w", "test", ["read", "write"], ws)

      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "test"
      )

      :ok
    end

    defp create_post!(blocks) do
      id = unique("ratchet-post")

      resp =
        send_json("/v1/data/mutate/test", "ratchet-ops-token", %{
          "mutations" => [
            %{
              "createOrReplace" => %{
                "_id" => id,
                "_type" => "post",
                "title" => "T",
                "blocks" => blocks
              }
            }
          ]
        })

      assert resp.status == 200, resp.resp_body
      id
    end

    defp post_doc(id), do: Content.get_document("drafts." <> id, "post", "test") |> elem(1)

    defp post_ops(id, body),
      do:
        send_json(
          "/v1/data/doc/test/post/#{id}/ops",
          "ratchet-ops-token",
          Map.put(body, "ifRev", post_doc(id).rev)
        )

    defp post_ids(id), do: Enum.map(post_doc(id).content["blocks"], & &1["id"])

    test "report-only: one op lands and its reply carries the warning" do
      id = create_post!([para("p1")])

      assert_reported(
        post_ops(id, %{"op" => append(bad_heading("h"))}),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert post_ids(id) == ["p1", "h"]
    end

    test "report-only: a batch lands and its reply carries the warning" do
      id = create_post!([para("p1")])

      assert_reported(
        post_ops(id, %{"ops" => [append(para("p2")), append(bad_heading("h"))]}),
        "value_not_allowed",
        "/blocks/2/level"
      )

      assert post_ids(id) == ["p1", "p2", "h"]
    end

    test "report-only: an op that loses a revless race and retries reports its error once",
         ctx do
      id = create_post!([para("p1")])
      draft = post_doc(id)
      :ok = Barkpark.PluginEnv.with_plugins([LoseRaceOnce], ctx)
      Process.put(LoseRaceOnce, draft.doc_id)
      Warnings.reset()

      assert {:ok, _} =
               Content.apply_document_block_op(
                 draft.doc_id,
                 "post",
                 append(bad_heading("h")),
                 "test",
                 workspace_id: draft.workspace_id,
                 project_id: draft.project_id
               )

      assert Process.get(LoseRaceOnce) == :lost

      assert [%{violations: [%{code: :value_not_allowed, path: "/blocks/1/level"}]}] =
               Enum.filter(Warnings.drain(), &(&1.code == "portable_doc_invalid"))

      assert post_ids(id) == ["p1", "h"]
    end

    test "refusing: one op and a batch are 409s and nothing is written" do
      id = create_post!([para("p1")])
      before = post_doc(id)
      refusing!()

      assert_refused(
        post_ops(id, %{"op" => append(bad_heading("h"))}),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert_refused(
        post_ops(id, %{"ops" => [append(para("p2")), append(bad_heading("h"))]}),
        "value_not_allowed",
        "/blocks/2/level"
      )

      assert post_doc(id).rev == before.rev
      assert post_ids(id) == ["p1"]
    end

    test "refusing: an op beside an old error still applies" do
      id = create_post!([bad_heading("h")])
      refusing!()
      assert_clean(post_ops(id, %{"op" => append(para("p2"))}))
      assert post_ids(id) == ["h", "p2"]
    end
  end

  describe "field ops (POST /v1/data/doc/:dataset/:type/:doc_id/fields/:field/ops)" do
    setup do
      {ws, proj} = TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: proj.id]
      Auth.create_token("ratchet-field-token", "w", "test", ["read", "write"], ws.id)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "ratchetfieldpub",
            "title" => "Ratchet field publication",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "description",
                "title" => "Description",
                "type" => "richText",
                "editor" => "blocks",
                "blocks" => %{"styles" => ["normal", "h2"], "marks" => ["strong"]}
              }
            ]
          },
          "test",
          scope
        )

      {:ok, scope: scope}
    end

    defp string_paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => "plain"}

    defp field_doc(scope, blocks \\ nil) do
      content = if blocks, do: %{"description" => %{"blocks" => blocks, "html" => ""}}, else: %{}

      {:ok, doc} =
        Content.create_document(
          "ratchetfieldpub",
          Map.merge(%{"doc_id" => unique("ratchet-field"), "title" => "T"}, content),
          "test",
          scope
        )

      doc
    end

    defp field_ops(doc, scope, ops) do
      {:ok, current} = Content.get_document(doc.doc_id, "ratchetfieldpub", "test", scope)
      id = String.replace_prefix(doc.doc_id, "drafts.", "")

      send_json(
        "/v1/data/doc/test/ratchetfieldpub/#{id}/fields/description/ops",
        "ratchet-field-token",
        %{"ops" => ops, "ifRev" => current.rev}
      )
    end

    defp field_ids(doc, scope) do
      {:ok, current} = Content.get_document(doc.doc_id, "ratchetfieldpub", "test", scope)
      Enum.map(get_in(current.content, ["description", "blocks"]) || [], & &1["id"])
    end

    test "report-only: the batch lands and its reply carries the warning", %{scope: scope} do
      doc = field_doc(scope)

      assert_reported(
        field_ops(doc, scope, [append(para("p1")), append(string_paragraph("s"))]),
        "wrong_field_type",
        "/blocks/1/content"
      )

      assert field_ids(doc, scope) == ["p1", "s"]
    end

    test "refusing: the batch is a 409 and the field stays unwritten", %{scope: scope} do
      doc = field_doc(scope)
      refusing!()

      assert_refused(
        field_ops(doc, scope, [append(para("p1")), append(string_paragraph("s"))]),
        "wrong_field_type",
        "/blocks/1/content"
      )

      assert field_ids(doc, scope) == []
    end

    test "refusing: an op beside an old error still applies", %{scope: scope} do
      doc = field_doc(scope, [string_paragraph("s")])
      refusing!()
      assert_clean(field_ops(doc, scope, [append(para("p1"))]))
      assert field_ids(doc, scope) == ["s", "p1"]
    end
  end

  describe "a paper through /v1/data/mutate" do
    setup do
      ws = TenancyFixtures.default_workspace_id!()
      Auth.create_token("ratchet-mutate-token", "w", "production", ["read", "write"], ws)
      :ok
    end

    defp mutate_paper(id, blocks),
      do:
        send_json("/v1/data/mutate/production", "ratchet-mutate-token", %{
          "mutations" => [
            %{
              "createOrReplace" => %{
                "_id" => id,
                "_type" => "paper",
                "title" => "Mutated paper",
                "blocks" => blocks
              }
            }
          ]
        })

    defp paper_draft_ids(id) do
      case Content.get_document("drafts." <> id, "paper", "production") do
        {:ok, draft} -> Enum.map(draft.content["blocks"], & &1["id"])
        _ -> nil
      end
    end

    defp seed_published!(blocks) do
      slug = unique("ratchet-mutate")

      {:ok, _} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "dataset" => "production",
            "blocks" => blocks
          })
        )

      slug
    end

    test "report-only: the draft lands and the mutate reply carries the warning" do
      id = unique("ratchet-mutate")

      assert_reported(
        mutate_paper(id, [para("a"), bad_heading("h")]),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert paper_draft_ids(id) == ["a", "h"]
    end

    test "refusing: the mutate is a 409 and no draft is written" do
      id = unique("ratchet-mutate")
      refusing!()

      assert_refused(
        mutate_paper(id, [para("a"), bad_heading("h")]),
        "value_not_allowed",
        "/blocks/1/level"
      )

      assert paper_draft_ids(id) == nil
    end

    test "refusing: an existing draft's old error never blocks its next write" do
      id = unique("ratchet-mutate")
      mutate_paper(id, [bad_heading("h")])
      refusing!()
      assert_clean(mutate_paper(id, [bad_heading("h"), para("b")]))
      assert paper_draft_ids(id) == ["h", "b"]
    end

    test "refusing: a draft's first write is judged against the published paper it replaces" do
      slug = seed_published!([para("a"), bad_heading("h")])
      refusing!()
      assert_clean(mutate_paper(slug, [para("a"), bad_heading("h"), para("b")]))
      assert paper_draft_ids(slug) == ["a", "h", "b"]

      other = seed_published!([para("a")])

      assert_refused(
        mutate_paper(other, [para("a"), bad_heading("h")]),
        "value_not_allowed",
        "/blocks/1/level"
      )
    end
  end

  describe "a plan paper (StudioChat.PlanPapers.publish)" do
    @fenced_bad_heading """
    # Plan

    Do the thing.

    ```portabledoc
    [{"id": "h", "type": "heading", "level": 9, "text": "Nine"}]
    ```
    """

    defp plan_warning do
      Enum.find(Warnings.drain(), &(&1.code == "portable_doc_invalid"))
    end

    test "report-only: a portabledoc fence that adds an error publishes and queues the warning" do
      Warnings.reset()

      assert {:ok, %{paper_id: slug}} =
               PlanPapers.publish(unique("sess"), unique("req"), @fenced_bad_heading)

      assert %{violations: [%{code: :value_not_allowed, path: path}]} = plan_warning()
      assert path =~ ~r"^/blocks/\d+/level$"

      assert Enum.any?(
               Content.get_paper(slug, "production").content["blocks"],
               &(&1["id"] == "h")
             )
    end

    test "refusing: the same plan is refused and no paper is written" do
      refusing!()
      session = unique("sess")
      request = unique("req")

      assert {:error, {:halted, message}} =
               PlanPapers.publish(session, request, @fenced_bad_heading)

      assert message =~ "adds 1 PortableDoc error(s): value_not_allowed"
      assert Content.get_paper(PlanPapers.slug_for(session, request), "production") == nil
    end

    test "refusing: plain markdown adds no error, so the plan still publishes" do
      refusing!()

      markdown = """
      # Plan

      ## Steps

      1. One
         1. Nested
      2. Two

      - [ ] open
      - [x] done

      | a | b |
      |---|---|
      | 1 |

      > quoted

      ###### Six

      ![alt](https://example.test/x.png) [link](https://example.test)
      """

      assert {:ok, %{paper_id: slug}} =
               PlanPapers.publish(unique("sess"), unique("req"), markdown)

      blocks = Content.get_paper(slug, "production").content["blocks"]
      assert length(Enum.uniq_by(blocks, & &1["type"])) > 3
      assert :ok = Validate.validate(%{"blocks" => blocks})
    end
  end
end
