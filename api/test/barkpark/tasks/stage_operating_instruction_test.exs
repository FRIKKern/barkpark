defmodule Barkpark.Tasks.StageOperatingInstructionTest do
  @moduledoc """
  TWO DURABLE SLOTS, TWO LIFETIMES (task-bd7476eecdede252).

  `content.disposition_reason` held BOTH a dated VERDICT ("this row's premise
  aged; here is what moved") and a standing OPERATING INSTRUCTION ("INDEX
  CONVENTION … READ BEFORE STAMPING"). They have opposite lifetimes — a later
  measurement SHOULD replace a verdict, and nothing newer supersedes an
  instruction — and they shared ONE slot, so the `note_would_supersede` guard
  left a lane ruling on a row that carried guidance exactly two moves: DESTROY
  THE GUIDANCE or RECORD NOTHING. Measured on the 2026-09-07 campaign: of 22
  rulings, TEN were safe only because the slot happened to be blank, and on
  `tgw11-bl-root-criteria-stamp-needs-close-window` — carrying a 1,960-byte
  pinned INDEX CONVENTION note — the verdict was never written at all.

  The fix is STRUCTURAL, not a delimiter convention: a second addressable key,
  `content.operating_instruction`, with its OWN supersede guard and its OWN
  opt-in flag.

  THE ARMS THAT MATTER ARE THE DESTRUCTIVE ONES, and both are required:

    * a VERDICT written onto a row whose INSTRUCTION slot is occupied — with
      `--supersede`, the destructive flag — leaves the instruction
      BYTE-IDENTICAL (`tgw11`'s real 1,960-byte note is the fixture);
    * an INSTRUCTION written onto a row carrying a VERDICT — with
      `--supersede-instruction` — leaves the verdict BYTE-IDENTICAL.

  A mechanism that only ever APPENDS would pass neither: both arms drive the
  DESTRUCTIVE flag and assert the other slot survived it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

  @token "barkpark-test-stage-instruction-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-stage-instruction", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
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

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp stage(conn, doc_id, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/tasks/#{doc_id}/stage", Jason.encode!(body))
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)

  defp staged_events(%Document{doc_id: doc_id}) do
    Repo.all(
      from(e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.staged",
        order_by: [asc: e.id]
      )
    )
  end

  # tgw11's real shape: a pinned convention whose whole purpose is to prevent
  # an off-by-one stamp. Padded to the MEASURED 1,960 bytes, because the row
  # names that size and a 40-byte stand-in would not exercise the same value.
  @index_convention "INDEX CONVENTION — READ BEFORE STAMPING: acceptance_criteria indices are " <>
                      "ZERO-BASED. The first criterion is 0, NOT 1. A stamp at the wrong index " <>
                      "lands on the neighbouring criterion and is unrepairable after close. " <>
                      String.duplicate(
                        "Do not re-derive this from the board's 1-based display. ",
                        31
                      ) <> "END PIN."

  @verdict "VERDICT 2026-09-07: this row's premise aged. seal.mjs prints b'=FAIL on its own " <>
             "because truth-grip-epic left @claimable_statuses; the hazard already happened."

  describe "the two slots are separately addressable" do
    test "a VERDICT with --supersede leaves an occupied INSTRUCTION byte-identical",
         %{conn: conn, scope: scope} do
      # THE ARM THAT MOTIVATED THE ROW. tgw11 carries pinned guidance in the
      # instruction slot AND an older verdict in the reason slot. The lane
      # rules on it with the DESTRUCTIVE flag — the one that was the only way
      # to write anything before — and the guidance must survive it.
      assert byte_size(@index_convention) == 1_960

      doc_id = uniq("instr-verdict-survives")

      task =
        mk_task!(doc_id, scope, %{
          "operating_instruction" => @index_convention,
          "disposition_reason" => "an older, now-stale reading"
        })

      resp = stage(conn, doc_id, %{state: "open", note: @verdict, supersede: true})
      assert resp.status == 200

      row = reload(task)

      # THE VERDICT MOVED...
      assert row.content["disposition_reason"] == @verdict
      # ...AND THE INSTRUCTION DID NOT. Byte-identical, asserted as bytes.
      assert row.content["operating_instruction"] == @index_convention
      assert byte_size(row.content["operating_instruction"]) == 1_960

      # The receipt says which slot it displaced and which it never touched.
      [ev] = staged_events(task)
      assert ev.document["staged"]["superseded_note"] == "an older, now-stale reading"
      assert ev.document["staged"]["superseded_instruction"] == nil
      assert ev.document["staged"]["operating_instruction"] == nil
    end

    test "an INSTRUCTION with --supersede-instruction leaves an occupied VERDICT byte-identical",
         %{conn: conn, scope: scope} do
      # THE REVERSE ARM. Required: a mechanism that only appends passes neither
      # direction, and a mechanism that shares one lock passes neither.
      doc_id = uniq("instr-instruction-survives")

      task =
        mk_task!(doc_id, scope, %{
          "disposition_reason" => @verdict,
          "operating_instruction" => "an older convention, since replaced"
        })

      resp =
        stage(conn, doc_id, %{
          state: "open",
          instruction: @index_convention,
          "supersede-instruction": true
        })

      assert resp.status == 200

      row = reload(task)
      assert row.content["operating_instruction"] == @index_convention
      assert row.content["disposition_reason"] == @verdict

      [ev] = staged_events(task)

      assert ev.document["staged"]["superseded_instruction"] ==
               "an older convention, since replaced"

      assert ev.document["staged"]["operating_instruction"] == @index_convention
      assert ev.document["staged"]["operating_instruction_key"] == "operating_instruction"
      assert ev.document["staged"]["superseded_note"] == nil
    end

    test "both land in ONE write and neither is reachable through the other's flag",
         %{conn: conn, scope: scope} do
      doc_id = uniq("instr-one-cas")
      task = mk_task!(doc_id, scope)

      resp =
        stage(conn, doc_id, %{state: "considering", note: @verdict, instruction: "read me first"})

      assert resp.status == 200

      row = reload(task)
      assert row.content["disposition_reason"] == @verdict
      assert row.content["operating_instruction"] == "read me first"
      # ONE write: one receipt, one rev.
      assert [_one] = staged_events(task)
    end
  end

  describe "the instruction slot has its OWN guard" do
    test "replacing a DIFFERENT instruction without the flag is a 409 that QUOTES it",
         %{conn: conn, scope: scope} do
      doc_id = uniq("instr-refuse")
      task = mk_task!(doc_id, scope, %{"operating_instruction" => @index_convention})

      body =
        conn
        |> stage(doc_id, %{state: "considering", instruction: "ignore the convention"})
        |> json_response(409)

      assert body["reason"] == "instruction_would_supersede"
      assert body["existing_instruction_length"] == String.length(@index_convention)
      assert body["existing_instruction_truncated"] == true
      assert String.starts_with?(body["existing_instruction"], "INDEX CONVENTION")
      assert body["message"] =~ "--supersede-instruction"
      assert body["message"] =~ "payload.staged.superseded_instruction"
      # It also teaches the OTHER slot, because a verdict-writer who lands here
      # is in the wrong field, not merely unauthorised.
      assert body["message"] =~ "--note"

      # NOTHING WAS WRITTEN.
      row = reload(task)
      assert row.content["operating_instruction"] == @index_convention
      assert row.content["lifecycle_status"] == "open"
      refute Map.has_key?(row.content, "engagement")
      assert staged_events(task) == []
    end

    test "--supersede does NOT license destroying an instruction (the guards are independent)",
         %{conn: conn, scope: scope} do
      # THE COLLISION THE SECOND KEY EXISTS TO REMOVE: one override for both
      # slots would mean a caller replacing a verdict on purpose is silently
      # also destroying guidance they never read.
      doc_id = uniq("instr-cross-flag")

      task =
        mk_task!(doc_id, scope, %{
          "operating_instruction" => @index_convention,
          "disposition_reason" => "older"
        })

      body =
        conn
        |> stage(doc_id, %{
          state: "considering",
          note: @verdict,
          instruction: "ignore the convention",
          supersede: true
        })
        |> json_response(409)

      assert body["reason"] == "instruction_would_supersede"

      row = reload(task)
      assert row.content["operating_instruction"] == @index_convention
      # ...and the note the supersede WAS authorised for is untouched too: a
      # refused stage writes nothing at all.
      assert row.content["disposition_reason"] == "older"
    end

    test "a re-write with the SAME text, a blank, and an absent slot are NOT refused",
         %{conn: conn, scope: scope} do
      doc_id = uniq("instr-nondestructive")
      task = mk_task!(doc_id, scope, %{"operating_instruction" => @index_convention})

      # same text — rewriting a string with itself destroys nothing
      assert stage(conn, doc_id, %{state: "considering", instruction: @index_convention}).status ==
               200

      # blank — overwrites nothing, leaves the slot alone
      assert stage(conn, doc_id, %{state: "considering", instruction: "   "}).status == 200
      assert reload(task).content["operating_instruction"] == @index_convention

      # no instruction at all, on a row that carries one
      assert stage(conn, doc_id, %{state: "considering", note: "a verdict"}).status == 200
      assert reload(task).content["operating_instruction"] == @index_convention
    end

    test "the RAW /v1/data/mutate door refuses content.operating_instruction and names the verb",
         %{scope: scope} do
      # A guard at the verb's seam is one a raw patch walks past — which would
      # put the destruction back one field over from where it was closed.
      doc_id = uniq("instr-raw")
      task = mk_task!(doc_id, scope, %{"operating_instruction" => @index_convention})

      set = %{
        "patch" => %{
          "id" => doc_id,
          "type" => "task",
          "set" => %{"operating_instruction" => "gone"}
        }
      }

      assert {:error, {:invalid_task_content, errors}} =
               Content.apply_mutations([set], @dataset, [source: :api] ++ scope)

      [message] = errors["operating_instruction"]
      assert message =~ "/v1/data/mutate"
      assert message =~ "bp task stage"
      assert message =~ "--instruction"

      assert reload(task).content["operating_instruction"] == @index_convention
    end
  end

  describe "legacy rows are not reclassified and nothing guesses" do
    test "a legacy disposition_reason stays put; the instruction slot is simply ABSENT",
         %{conn: conn, scope: scope} do
      # A row written BEFORE the split, whose reason slot holds guidance-shaped
      # text. Nothing migrates it, nothing reclassifies it, and the first
      # --instruction on it is unguarded because there is nothing to displace.
      legacy = "DO NOT EXECUTE THIS ROW AS WRITTEN — the fixture it names was deleted."
      doc_id = uniq("instr-legacy")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => legacy})

      row = reload(task)
      refute Map.has_key?(row.content, "operating_instruction")

      assert stage(conn, doc_id, %{state: "considering", instruction: legacy}).status == 200

      row = reload(task)
      # The legacy value is BYTE-IDENTICAL and still in the reason slot: the
      # code did not move it, copy-and-delete it, or decide what kind it was.
      assert row.content["disposition_reason"] == legacy
      assert row.content["operating_instruction"] == legacy
    end
  end

  describe "the manifest advertises the second slot" do
    test "task.stage carries --instruction and --supersede-instruction, and says why" do
      cmd =
        Barkpark.Plugins.Tasks.cli_commands()
        |> Enum.find(&(&1.id == "task.stage"))

      flags = Map.new(cmd.flags, &{&1.name, &1})

      instruction = Map.get(flags, "instruction")
      override = Map.get(flags, "supersede-instruction")

      assert instruction, "task.stage advertises no --instruction flag"
      assert override, "task.stage advertises no --supersede-instruction flag"

      assert instruction.summary =~ "content.operating_instruction"
      assert instruction.summary =~ "instruction_would_supersede"
      # The two-lifetimes claim is the reason the flag exists; a help string
      # that only says "writes a field" teaches nothing.
      assert instruction.summary =~ "--supersede"
      assert override.summary =~ "payload.staged.superseded_instruction"
      assert cmd.summary =~ "content.operating_instruction"
    end

    test "Stage names the key it writes, and it is NOT the reason key" do
      assert Tasks.Stage.operating_instruction_key() == "operating_instruction"
      refute Tasks.Stage.operating_instruction_key() == Tasks.Stage.durable_reason_key()
    end
  end
end
