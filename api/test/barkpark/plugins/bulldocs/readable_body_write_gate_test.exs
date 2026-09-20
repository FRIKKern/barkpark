defmodule Barkpark.Plugins.Bulldocs.ReadableBodyWriteGateTest do
  @moduledoc """
  THE PRODUCER GATE (row `dr-w24-bl-paper-writer-accepts-unreadable-bodies`).

  NAMED FAILURE MODE: the paper write path accepted a `content` whose body no
  reader can classify — `Barkpark.Content.Papers.reader_source/3` answers
  `{:error, :semantic_empty}` for it — and said nothing. The write returned
  201/200, the document persisted, and the FIRST complaint arrived at read
  time, as a 422, for every reader forever. 68 of 727 published papers on
  guerrilla carry such a body, in three writer dialects.

  These tests drive the REAL door (`Content.apply_mutations/3` — the
  `/v1/data/mutate` verb `bp` and every SDK writer uses) and assert a named,
  enveloped refusal BEFORE any row is written.

  Each dialect test also asserts the reader's verdict on the same content
  (`reader_source/3` → `{:error, :semantic_empty}`), so the gate's premise is
  re-earned by the classifier itself rather than by this file's opinion.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers
  alias Barkpark.Plugins.Bulldocs.ReadableBody
  alias Barkpark.Tenancy

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rb-ws-#{suffix}", name: "rb-ws"})
    {:ok, project} = Tenancy.create_project(ws, %{slug: "rb-p-#{suffix}", name: "rb-p"})
    %{ws: ws, project: project}
  end

  # ── the three observed writer dialects ────────────────────────────────

  # 1. body = a ProseMirror doc node.
  defp dialect(:prosemirror),
    do: %{
      "body" => %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}
        ]
      }
    }

  # 2. body = {content} with no type.
  defp dialect(:typeless_wrapper),
    do: %{
      "body" => %{
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}
        ]
      }
    }

  # 3. body = null, nodes parked at top-level content.
  defp dialect(:parked_nodes),
    do: %{
      "body" => nil,
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}
      ]
    }

  defp create_paper(content, doc_id, %{ws: ws, project: project}) do
    Content.apply_mutations(
      [
        %{
          "create" => %{
            "_id" => doc_id,
            "_type" => "paper",
            "title" => "Dialect probe",
            "content" => content
          }
        }
      ],
      "production",
      source: :api,
      workspace_id: ws.id,
      project_id: project.id
    )
  end

  defp replace_paper(content, doc_id, %{ws: ws, project: project}) do
    Content.apply_mutations(
      [
        %{
          "createOrReplace" => %{
            "_id" => doc_id,
            "_type" => "paper",
            "title" => "Dialect probe",
            "content" => content
          }
        }
      ],
      "production",
      source: :api,
      workspace_id: ws.id,
      project_id: project.id
    )
  end

  describe "criterion 1 — the producer gate refuses each unreadable dialect at write time" do
    for {name, label} <- [
          prosemirror: "body = a ProseMirror doc node",
          typeless_wrapper: "body = {content} with no type",
          parked_nodes: "body = null with nodes parked at top-level content"
        ] do
      test "create is refused: #{label}", ctx do
        content = dialect(unquote(name))
        doc_id = "rb-create-#{unquote(name)}-#{System.unique_integer([:positive])}"

        # The classifier itself says this body is unreadable — the gate's premise.
        assert {:error, :semantic_empty} =
                 Papers.reader_source(
                   %Document{type: "paper", doc_id: doc_id, content: content},
                   "production"
                 )

        assert {:error, {:halted, reason}} = create_paper(content, doc_id, ctx)
        assert reason =~ "no reader can read"
        assert reason =~ "content.blocks"

        # …and nothing was written: the refusal precedes the row.
        assert {:error, :not_found} =
                 Content.get_document("drafts.#{doc_id}", "paper", "production",
                   workspace_id: ctx.ws.id
                 )

        assert {:error, :not_found} =
                 Content.get_document(doc_id, "paper", "production", workspace_id: ctx.ws.id)
      end

      test "createOrReplace is refused: #{label}", ctx do
        content = dialect(unquote(name))
        doc_id = "rb-replace-#{unquote(name)}-#{System.unique_integer([:positive])}"

        assert {:error, {:halted, reason}} = replace_paper(content, doc_id, ctx)
        assert reason =~ "no reader can read"
      end
    end
  end

  describe "criterion 2 — negative arm: every shape a reader CAN read still writes" do
    @readable_blocks [
      %{"id" => "h", "type" => "heading", "level" => 1, "text" => "Title"},
      %{"id" => "p", "type" => "paragraph", "text" => "Real prose."}
    ]

    # Enumerated from `Projection.read_blocks/1`'s OWN clauses — the function
    # `Content.Envelope.promote_paper_blocks/2` calls, i.e. the exact promotion
    # `reader_source/3` reads. Retyping a list of "allowed shapes" here would be
    # the very drift this gate exists to stop.
    test "each read_blocks/1 clause writes unchanged", ctx do
      shapes = [
        {"content.blocks", %{"blocks" => @readable_blocks}},
        {"content.body.blocks", %{"body" => %{"blocks" => @readable_blocks}}},
        {"content.body as a block list", %{"body" => @readable_blocks}},
        {"content.body as markdown", %{"body" => "# Title\n\nReal prose."}}
      ]

      for {label, content} <- shapes do
        doc_id = "rb-ok-#{System.unique_integer([:positive])}"

        written = create_paper(content, doc_id, ctx)

        assert match?({:ok, {_tx, [_result]}}, written),
               "readable shape refused: #{label} — got #{inspect(written)}"

        classified = ReadableBody.classify(content)
        assert classified == :ok, "classify/1 refused #{label} — got #{inspect(classified)}"
      end
    end

    test "a body_html-only (pre-doctrine) paper still writes", ctx do
      doc_id = "rb-html-#{System.unique_integer([:positive])}"
      content = %{"body_html" => "<h2>Legit heading</h2><p>Prose.</p>"}

      assert {:ok, {_tx, [_result]}} = create_paper(content, doc_id, ctx)
    end

    test "a paper write that carries no body signal at all is not this gate's business", ctx do
      doc_id = "rb-nobody-#{System.unique_integer([:positive])}"

      assert {:ok, {_tx, [_result]}} = create_paper(%{"summary" => "meta only"}, doc_id, ctx)
      assert :ok = ReadableBody.classify(%{"summary" => "meta only"})
      assert :ok = ReadableBody.classify(nil)
    end

    test "non-paper types are untouched by this gate", ctx do
      %{ws: ws, project: project} = ctx

      assert {:ok, {_tx, [_result]}} =
               Content.apply_mutations(
                 [
                   %{
                     "create" => %{
                       "_id" => "rb-post-#{System.unique_integer([:positive])}",
                       "_type" => "post",
                       "title" => "Not a paper",
                       "content" => dialect(:prosemirror)
                     }
                   }
                 ],
                 "production",
                 source: :api,
                 workspace_id: ws.id,
                 project_id: project.id
               )
    end

    test "the existing broken population is not touched — the gate reads only the incoming write",
         ctx do
      %{ws: ws, project: project} = ctx
      doc_id = "rb-legacy-#{System.unique_integer([:positive])}"

      # Plant a broken row the way the 68 were born — straight into storage,
      # bypassing the write path, exactly as a pre-gate writer left them.
      {:ok, legacy} =
        %Document{}
        |> Document.changeset(%{
          "doc_id" => "drafts.#{doc_id}",
          "type" => "paper",
          "title" => "Legacy broken",
          "dataset" => "production",
          "status" => "draft",
          "rev" => Barkpark.Content.Writer.generate_rev(),
          "content" => dialect(:prosemirror),
          "workspace_id" => ws.id,
          "project_id" => project.id
        })
        |> Barkpark.Repo.insert()

      # It stays exactly as it was — no read, no rewrite, no deletion.
      assert legacy.content == dialect(:prosemirror)

      # And the repair write (pe-w2-bl-blockless-wave-papers' job) sails through:
      # the merged content now carries a real block list, so the reader's own
      # promotion succeeds and the gate has nothing to say.
      assert {:ok, {_tx, [_result]}} =
               Content.apply_mutations(
                 [
                   %{
                     "patch" => %{
                       "id" => "drafts.#{doc_id}",
                       "type" => "paper",
                       "set" => %{"blocks" => @readable_blocks}
                     }
                   }
                 ],
                 "production",
                 source: :api,
                 workspace_id: ws.id,
                 project_id: project.id
               )
    end

    # STATED CONSEQUENCE, asserted rather than discovered later: mutate `patch`
    # merges the stored content and re-persists the WHOLE document, so a
    # metadata-only edit of one of the 68 legacy rows would write the unreadable
    # body forward — and this gate refuses it. Nothing at rest changes (the row
    # is untouched, still readable-by-nobody exactly as before); the edit simply
    # has to carry the repair. This is the gate being a gate that can lose.
    test "a metadata-only patch of a legacy-broken row is refused, and the row is untouched",
         ctx do
      %{ws: ws, project: project} = ctx
      doc_id = "rb-legacy-meta-#{System.unique_integer([:positive])}"

      {:ok, legacy} =
        %Document{}
        |> Document.changeset(%{
          "doc_id" => "drafts.#{doc_id}",
          "type" => "paper",
          "title" => "Legacy broken",
          "dataset" => "production",
          "status" => "draft",
          "rev" => Barkpark.Content.Writer.generate_rev(),
          "content" => dialect(:prosemirror),
          "workspace_id" => ws.id,
          "project_id" => project.id
        })
        |> Barkpark.Repo.insert()

      assert {:error, {:halted, reason}} =
               Content.apply_mutations(
                 [
                   %{
                     "patch" => %{
                       "id" => "drafts.#{doc_id}",
                       "type" => "paper",
                       "set" => %{"summary" => "just a metadata edit"}
                     }
                   }
                 ],
                 "production",
                 source: :api,
                 workspace_id: ws.id,
                 project_id: project.id
               )

      assert reason =~ "no reader can read"

      {:ok, after_doc} =
        Content.get_document("drafts.#{doc_id}", "paper", "production", workspace_id: ws.id)

      assert after_doc.content == legacy.content
      assert after_doc.rev == legacy.rev
    end
  end

  describe "criterion 3 — each disjunct of the door predicate decides alone" do
    # WHY THIS DESCRIBE EXISTS. `ReadableBody.body_bearing?/1` is a four-way
    # disjunction — "body" | "blocks" | "body_html" | a top-level "content"
    # list — and every fixture above carries a "body" key (`:parked_nodes` is
    # %{"body" => nil, "content" => [...]}), so the FIRST term admitted all of
    # them and the other three never decided anything: collapsing the
    # disjunction to `Map.has_key?(content, "body")` alone left this file 39
    # tests, 0 failures. Each test below carries exactly ONE of the remaining
    # three signals and NO "body" key, so deleting that one term — and only
    # that term — flips the write from refused to accepted and reds exactly
    # this test. Each arm pairs the refusal with a POSITIVE CONTROL: the same
    # write with its signal removed, which must take the "a write carrying no
    # body signal at all" path the moduledoc names — `classify/1` -> `:ok`,
    # write accepted — so the arm cannot be satisfied by some unrelated
    # refusal. These are all refusals on origin/main today; the arms pin live
    # behaviour and change nothing.

    test "the \"blocks\" disjunct decides alone: blocks as a ProseMirror map, no body key", ctx do
      # `Projection.read_blocks/1` matches "blocks" only `when is_list(blocks)`,
      # so a ProseMirror doc NODE parked at content.blocks is unreadable — and
      # only `Map.has_key?(content, "blocks")` brings it through the door.
      content = %{
        "blocks" => %{
          "type" => "doc",
          "content" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}
          ]
        }
      }

      refute Map.has_key?(content, "body")
      refute Map.has_key?(content, "body_html")
      refute is_list(Map.get(content, "content"))

      assert ReadableBody.classify(content) == {:error, :unreadable_body}

      doc_id = "rb-blocks-map-#{System.unique_integer([:positive])}"
      written = create_paper(content, doc_id, ctx)
      halted? = match?({:error, {:halted, _reason}}, written)
      assert halted?, "blocks-as-prosemirror-map write was not refused — got #{inspect(written)}"
      {:error, {:halted, reason}} = written
      assert reason =~ "no reader can read"

      # POSITIVE CONTROL — the door, not some other refusal. Drop the one
      # signal and the same write offers no body at all, so the gate has
      # nothing to judge and the row lands.
      control = Map.delete(content, "blocks")
      assert ReadableBody.classify(control) == :ok

      control_id = "rb-blocks-map-control-#{System.unique_integer([:positive])}"
      control_written = create_paper(control, control_id, ctx)
      control_ok? = match?({:ok, {_tx, [_result]}}, control_written)

      assert control_ok?,
             "control (blocks key removed) was not accepted — got #{inspect(control_written)}"
    end

    test "the \"body_html\" disjunct decides alone: a whitespace body_html, no body key", ctx do
      # `html_source?/1` trims, so "   " is NOT an HTML source; nothing else in
      # this content offers a body, so only
      # `Map.has_key?(content, "body_html")` opens the door.
      content = %{"body_html" => "   \n\t  "}

      refute Map.has_key?(content, "body")
      refute Map.has_key?(content, "blocks")
      refute is_list(Map.get(content, "content"))

      assert ReadableBody.classify(content) == {:error, :unreadable_body}

      doc_id = "rb-blank-html-#{System.unique_integer([:positive])}"
      written = create_paper(content, doc_id, ctx)
      halted? = match?({:error, {:halted, _reason}}, written)
      assert halted?, "whitespace body_html write was not refused — got #{inspect(written)}"
      {:error, {:halted, reason}} = written
      assert reason =~ "no reader can read"

      # POSITIVE CONTROL — signal removed, no body offered, write lands.
      control = Map.delete(content, "body_html")
      assert ReadableBody.classify(control) == :ok

      control_id = "rb-blank-html-control-#{System.unique_integer([:positive])}"
      control_written = create_paper(control, control_id, ctx)
      control_ok? = match?({:ok, {_tx, [_result]}}, control_written)

      assert control_ok?,
             "control (body_html key removed) was not accepted — got #{inspect(control_written)}"
    end

    test "the top-level content-list disjunct decides alone: parked nodes with NO body key",
         ctx do
      # Dialect 3 without its null "body" key — the shape a writer produces by
      # simply omitting the key rather than setting it to nil. No
      # `read_blocks/1` clause reads a top-level "content", so only
      # `is_list(Map.get(content, "content"))` brings it through the door.
      content = %{
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}
        ]
      }

      refute Map.has_key?(content, "body")
      refute Map.has_key?(content, "blocks")
      refute Map.has_key?(content, "body_html")

      assert ReadableBody.classify(content) == {:error, :unreadable_body}

      doc_id = "rb-parked-nobody-#{System.unique_integer([:positive])}"
      written = create_paper(content, doc_id, ctx)
      halted? = match?({:error, {:halted, _reason}}, written)
      assert halted?, "parked-nodes-without-body write was not refused — got #{inspect(written)}"
      {:error, {:halted, reason}} = written
      assert reason =~ "no reader can read"

      # POSITIVE CONTROL — the LIST-ness is what decides, not the key: the same
      # key holding a non-list offers no body, so the write lands.
      control = %{"content" => %{"type" => "doc"}}
      assert ReadableBody.classify(control) == :ok

      control_id = "rb-parked-nobody-control-#{System.unique_integer([:positive])}"
      control_written = create_paper(control, control_id, ctx)
      control_ok? = match?({:ok, {_tx, [_result]}}, control_written)

      assert control_ok?,
             "control (content held a map, not a list) was not accepted — got #{inspect(control_written)}"
    end
  end
end
