defmodule BarkparkWeb.PaperCanvasLeaseTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.PaperCanvasLease
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @scope %{
    workspace_id: "workspace",
    project_id: "project",
    dataset: "production",
    doc_type: "paper",
    slug: "lease-paper",
    authority: "user:author"
  }

  test "accepted retained boundaries round-trip only in their exact current owners" do
    table = table("nested-table")
    blocks = [section("outer", [paragraph("intro"), table])]
    owners = %{{:section, "outer"} => MapSet.new(["nested-table"])}

    tokens = PaperCanvasLease.issue(@scope, owners, blocks, 12)
    assert map_size(tokens) == 1

    attempt = %{
      attempted?: true,
      malformed?: false,
      pending?: false,
      key: PaperCanvasLease.paper_key(@scope),
      tokens: Map.values(tokens)
    }

    assert {:ok, %{slug: "lease-paper", owners: ^owners}, resumed_tokens} =
             PaperCanvasLease.resume(attempt, @scope, blocks, true)

    assert resumed_tokens == tokens

    moved = [section("other", [table]), section("outer", [paragraph("intro")])]
    assert :halt = PaperCanvasLease.resume(attempt, @scope, moved, true)

    changed = [section("outer", [paragraph("intro"), paragraph("nested-table")])]
    assert :halt = PaperCanvasLease.resume(attempt, @scope, changed, true)

    grid = [put_in(section("outer", [table]), ["layout"], %{"mode" => "grid"})]
    assert :halt = PaperCanvasLease.resume(attempt, @scope, grid, true)
  end

  test "leases bind tenant, document, principal and expiry while foreign signed leases are ignored" do
    blocks = [table("owned")]
    owners = %{document: MapSet.new(["owned"])}
    [token] = @scope |> PaperCanvasLease.issue(owners, blocks, 3) |> Map.values()

    attempt = %{
      attempted?: true,
      malformed?: false,
      pending?: false,
      key: PaperCanvasLease.paper_key(@scope),
      tokens: [token]
    }

    for {key, value} <- [
          {:workspace_id, "other-workspace"},
          {:project_id, "other-project"},
          {:authority, "user:other"}
        ] do
      assert :halt = PaperCanvasLease.resume(attempt, Map.put(@scope, key, value), blocks, true)
    end

    for {key, value} <- [
          {:dataset, "staging"},
          {:doc_type, "session"},
          {:slug, "other-paper"}
        ] do
      assert :none = PaperCanvasLease.resume(attempt, Map.put(@scope, key, value), blocks, true)
    end

    assert :none = PaperCanvasLease.resume(attempt, @scope, blocks, false)
    assert :halt = PaperCanvasLease.resume(attempt, @scope, blocks, true, max_age: -1)

    assert :halt =
             PaperCanvasLease.resume(
               %{attempt | tokens: [token <> "tampered"]},
               @scope,
               blocks,
               true
             )
  end

  test "capture bounds raw reconnect input and pending state never grants ownership" do
    assert %{attempted?: false} = PaperCanvasLease.capture_params(%{})

    assert %{attempted?: true, pending?: true, tokens: []} =
             pending =
             PaperCanvasLease.capture_params(%{
               "paper_canvas_lease_pending" => true,
               "paper_canvas_lease_key" => PaperCanvasLease.paper_key(@scope)
             })

    assert :pending = PaperCanvasLease.resume(pending, @scope, [table("owned")], true)

    token =
      @scope
      |> PaperCanvasLease.issue(%{document: MapSet.new(["owned"])}, [table("owned")], 1)
      |> Map.fetch!("owned")

    assert {:pending, %{owners: %{document: owned}}, %{"owned" => ^token}} =
             PaperCanvasLease.resume(%{pending | tokens: [token]}, @scope, [table("owned")], true)

    assert MapSet.member?(owned, "owned")

    assert %{attempted?: true, malformed?: true} =
             PaperCanvasLease.capture_params(%{
               "paper_canvas_lease_overflow" => true,
               "paper_canvas_lease_key" => PaperCanvasLease.paper_key(@scope)
             })

    assert %{malformed?: true, tokens: []} =
             PaperCanvasLease.capture_params(%{
               "paper_canvas_lease_key" => PaperCanvasLease.paper_key(@scope),
               "paper_canvas_leases" => [String.duplicate("x", 2049)]
             })

    assert %{attempted?: true, malformed?: true} =
             PaperCanvasLease.capture_params(%{
               "paper_canvas_lease_key" => PaperCanvasLease.paper_key(@scope),
               "paper_canvas_leases" => "not-an-array"
             })

    assert %{malformed?: true, tokens: []} =
             PaperCanvasLease.capture_params(%{
               "paper_canvas_lease_key" => PaperCanvasLease.paper_key(@scope),
               "paper_canvas_leases" => Enum.map(1..65, &"token-#{&1}")
             })

    blocks = Enum.map(1..65, &table("owned-#{&1}"))
    owners = %{document: MapSet.new(Enum.map(blocks, & &1["id"]))}
    assert :overflow = PaperCanvasLease.issue(@scope, owners, blocks, 1)
  end

  test "a matching reader editing key scopes malformed input to this document" do
    malformed = %{
      "paper_canvas_leases" => [42],
      "paper_canvas_lease_key" => "production:paper:one"
    }

    assert %{attempted?: true, malformed?: true} = PaperCanvasLease.capture_params(malformed)

    assert :none =
             PaperCanvasLease.resume(
               PaperCanvasLease.capture_params(malformed),
               %{@scope | slug: "two"},
               [table("owned")],
               true
             )

    assert :halt =
             PaperCanvasLease.resume(
               PaperCanvasLease.capture_params(malformed),
               %{@scope | slug: "one"},
               [table("owned")],
               true
             )
  end

  test "same-document signed claims with a changed authority scope halt instead of falling through" do
    blocks = [table("owned")]

    token =
      @scope
      |> PaperCanvasLease.issue(%{document: MapSet.new(["owned"])}, blocks, 1)
      |> Map.fetch!("owned")

    attempt = %{
      attempted?: true,
      malformed?: false,
      pending?: false,
      key: PaperCanvasLease.paper_key(@scope),
      tokens: [token]
    }

    assert :halt =
             PaperCanvasLease.resume(attempt, %{@scope | authority: "user:other"}, blocks, true)

    changed_scope = %{@scope | authority: "user:other"}

    current =
      PaperCanvasLease.issue(changed_scope, %{document: MapSet.new(["owned"])}, blocks, 1)[
        "owned"
      ]

    assert :halt =
             PaperCanvasLease.resume(
               %{attempt | tokens: [current, token]},
               changed_scope,
               blocks,
               true
             )

    assert :halt =
             PaperCanvasLease.resume(
               %{attempt | pending?: true, tokens: [current, token]},
               changed_scope,
               blocks,
               true
             )
  end

  test "anonymous ownership never issues transferable leases" do
    assert :unsupported =
             PaperCanvasLease.issue(
               %{@scope | authority: nil},
               %{document: MapSet.new(["owned"])},
               [table("owned")],
               1
             )
  end

  test "leases refuse boundaries the native projection cannot safely admit" do
    malformed_table = %{
      "id" => "owned",
      "type" => "table",
      "rows" => [[[%{"type" => "unknown", "opaque" => true}]]]
    }

    assert :overflow =
             PaperCanvasLease.issue(
               @scope,
               %{document: MapSet.new(["owned"])},
               [malformed_table],
               1
             )

    empty_section = section("empty", [])

    assert :overflow =
             PaperCanvasLease.issue(
               @scope,
               %{document: MapSet.new(["empty"])},
               [empty_section],
               1
             )
  end

  test "issuance refuses an aggregate token payload over the byte cap without partial leases" do
    scope = %{@scope | workspace_id: String.duplicate("workspace", 70)}
    blocks = Enum.map(1..50, &table("owned-#{&1}"))

    individual_tokens =
      Enum.map(blocks, fn block ->
        PaperCanvasLease.issue(scope, %{document: MapSet.new([block["id"]])}, blocks, 1)[
          block["id"]
        ]
      end)

    assert Enum.all?(individual_tokens, &(is_binary(&1) and byte_size(&1) < 2_048))
    assert Enum.sum(Enum.map(individual_tokens, &byte_size/1)) > 32_768

    assert :overflow =
             PaperCanvasLease.issue(
               scope,
               %{document: MapSet.new(Enum.map(blocks, & &1["id"]))},
               blocks,
               1
             )
  end

  test "intentional lifecycle reset clears every reconnect ownership state" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        paper_canvas_retained: %{slug: "paper", owners: %{document: MapSet.new(["owned"])}},
        paper_canvas_lease_tokens: %{"owned" => "token"},
        paper_canvas_resume_halt: true,
        paper_canvas_resume_status: :blocked,
        paper_canvas_resume_attempt: %{attempted?: true}
      }
    }

    reset = PaperCanvasLease.reset_socket(socket)

    assert reset.assigns.paper_canvas_retained == nil
    assert reset.assigns.paper_canvas_lease_tokens == %{}
    assert reset.assigns.paper_canvas_resume_halt == false
    assert reset.assigns.paper_canvas_resume_status == :none
    assert reset.assigns.paper_canvas_resume_attempt.attempted? == false
  end

  test "same-document rebuild preserves issued and blocked lease state while a paper switch clears it" do
    blocks = [table("owned")]

    paper = %{
      workspace_id: "workspace",
      project_id: "project",
      type: "paper",
      doc_id: "drafts.lease-paper"
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        dataset: "production",
        current_user: %{id: "author"},
        paper_canvas_retained: %{slug: paper.doc_id, owners: %{document: MapSet.new(["owned"])}}
      }
    }

    issued =
      PaperCanvasLease.issue_socket(
        socket,
        paper,
        %{document: MapSet.new(["owned"])},
        blocks,
        1
      )

    rebuilt = PaperCanvasLease.resume_socket(issued, paper, blocks, true)
    assert rebuilt.assigns.paper_canvas_resume_status == :resumed
    assert rebuilt.assigns.paper_canvas_lease_tokens == issued.assigns.paper_canvas_lease_tokens
    assert rebuilt.assigns.paper_canvas_retained == issued.assigns.paper_canvas_retained

    blocked = %{
      issued
      | assigns:
          issued.assigns
          |> Map.put(:paper_canvas_resume_status, :blocked)
          |> Map.put(:paper_canvas_resume_halt, true)
    }

    rebuilt_blocked = PaperCanvasLease.resume_socket(blocked, paper, blocks, true)
    assert rebuilt_blocked.assigns.paper_canvas_resume_status == :blocked
    assert rebuilt_blocked.assigns.paper_canvas_resume_halt

    switched =
      PaperCanvasLease.resume_socket(
        issued,
        %{paper | doc_id: "drafts.other-paper"},
        blocks,
        true
      )

    assert switched.assigns.paper_canvas_resume_status == :none
    assert switched.assigns.paper_canvas_lease_tokens == %{}
    assert switched.assigns.paper_canvas_retained == nil

    tenant_switched =
      PaperCanvasLease.resume_socket(
        issued,
        %{paper | workspace_id: "other-workspace"},
        blocks,
        true
      )

    assert tenant_switched.assigns.paper_canvas_resume_status == :none
    assert tenant_switched.assigns.paper_canvas_lease_tokens == %{}
    assert tenant_switched.assigns.paper_canvas_retained == nil

    authority_switched = %{
      issued
      | assigns: Map.put(issued.assigns, :current_user, %{id: "other-author"})
    }

    authority_switched = PaperCanvasLease.resume_socket(authority_switched, paper, blocks, true)
    assert authority_switched.assigns.paper_canvas_lease_tokens == %{}
    assert authority_switched.assigns.paper_canvas_retained == nil

    project_switched =
      PaperCanvasLease.resume_socket(
        issued,
        %{paper | project_id: "other-project"},
        blocks,
        true
      )

    assert project_switched.assigns.paper_canvas_lease_tokens == %{}
    assert project_switched.assigns.paper_canvas_retained == nil

    unauthorized = PaperCanvasLease.resume_socket(issued, paper, blocks, false)
    assert unauthorized.assigns.paper_canvas_lease_tokens == %{}
    assert unauthorized.assigns.paper_canvas_retained == nil
    assert unauthorized.assigns.paper_canvas_resume_halt == false
  end

  test "scope preserves the exact draft document id used by the rendered editor key" do
    scope =
      PaperCanvasLease.scope(
        %{dataset: "production", current_user: %{id: "author"}},
        %{
          workspace_id: "workspace",
          project_id: "project",
          type: "paper",
          doc_id: "drafts.lease-paper"
        }
      )

    assert scope.slug == "drafts.lease-paper"
    assert PaperCanvasLease.paper_key(scope) == "production:paper:drafts.lease-paper"

    blocks = [table("owned")]
    owners = %{document: MapSet.new(["owned"])}
    tokens = PaperCanvasLease.issue(scope, owners, blocks, 1)

    assert {:ok, %{slug: "drafts.lease-paper", owners: ^owners}, ^tokens} =
             PaperCanvasLease.resume(
               %{
                 attempted?: true,
                 malformed?: false,
                 pending?: false,
                 key: PaperCanvasLease.paper_key(scope),
                 tokens: Map.values(tokens)
               },
               scope,
               blocks,
               true
             )
  end

  test "halt renders an immediate warning beside a stable client-preserved editor root" do
    html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "drafts.lease-paper",
        doc_type: "paper",
        blocks: [table("owned")],
        paper_rev: 2,
        dataset: "production",
        api_token_raw: "",
        canvas_eligible: true,
        canvas_resume_halt: true,
        canvas_resume_state: :pending
      )

    assert html =~ ~s(data-test-id="paper-canvas-resume-warning")
    assert html =~ "Reloading the server version discards unsaved local edits"
    assert html =~ "preserved canvas draft fragments"
    assert html =~ ~s(data-paper-canvas-export-draft)
    assert html =~ ~s(data-paper-editor-target="paper-editor-drafts.lease-paper")
    assert html =~ ~s(data-test-id="paper-canvas-recovery-controls")
    assert html =~ ~s(<button type="button" data-test-id="paper-canvas-reload-server")
    assert html =~ ~s(id="paper-editor-drafts.lease-paper")
    assert html =~ ~s(data-paper-doc-key="production:paper:drafts.lease-paper")
    assert html =~ ~s(data-paper-canvas-resume-halt="true")
    assert html =~ ~s(data-paper-canvas-resume-state="pending")
    assert html =~ ~s(inert)
    refute html =~ ~s(phx-update="ignore")
    refute html =~ ~s(<bp-paper-canvas)
  end

  test "mutation replies return leases only for the exact origin run" do
    first = table("first")
    second = table("second")

    blocks = [
      paragraph("before"),
      first,
      %{"id" => "split", "type" => "form"},
      paragraph("after"),
      second
    ]

    owners = %{document: MapSet.new(["first", "second"])}
    tokens = PaperCanvasLease.issue(@scope, owners, blocks, 1)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        paper_doc: %{content: %{"blocks" => blocks}},
        paper_canvas_lease_tokens: tokens
      }
    }

    assert Paper.canvas_reply_leases(
             socket,
             {:ok, %{container_kind: "document", container_run_ids: ["before", "first"]}},
             []
           ) == [tokens["first"]]
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => []}

  defp table(id),
    do: %{"id" => id, "type" => "table", "head" => [[], []], "rows" => [[[], []]]}

  defp section(id, blocks), do: %{"id" => id, "type" => "section", "blocks" => blocks}
end
