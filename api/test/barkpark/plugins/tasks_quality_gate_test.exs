defmodule Barkpark.Plugins.TasksQualityGateTest do
  @moduledoc """
  Locks the Tasks plugin's `before_save` authoring quality gate (parity §6):

    * an empty/blank title HALTS the save with `{:error, {:halted, reason}}`
      (→ HTTP 409) and writes nothing;
    * a fresh, well-titled task with zero `acceptance_criteria` SAVES but emits
      a soft `Logger.warning` — never a hard stop;
    * a malformed `acceptance_criteria` (not a list, or a list with a non-map
      entry) is REJECTED by the gate;
    * a partial metadata update of an already-titled task is NOT blocked (the
      title falls back to the stored row);
    * a well-formed task passes cleanly.

  The plugin is wired in via the `:plugins` env so `Barkpark.Plugins.Hooks`
  fires its hooks deterministically; RegistryCase restores the baseline.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Plugins.Hooks

  @dataset "tasks_quality_gate_test"

  setup do
    Application.put_env(:barkpark, :plugins, [Barkpark.Plugins.Tasks])
    # RegistryCase + DataCase both restore the env baseline on exit.
    :ok
  end

  defp base_content(extra \\ %{}) do
    Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)
  end

  defp create_task(id, attrs) do
    Content.create_document(
      "task",
      Map.merge(%{"doc_id" => id, "content" => base_content()}, attrs),
      @dataset
    )
  end

  # A payload shaped like the one `Barkpark.Content.Writer` builds for
  # `before_save`, so we exercise the gate through the real dispatcher.
  defp before_save(doc, prev \\ nil) do
    Hooks.fire(:before_save, %{
      event: :before_save,
      doc: Map.put(doc, "type", "task"),
      dataset: @dataset,
      prev_doc: prev,
      ctx: %{}
    })
  end

  defp before_publish(content) do
    Hooks.fire(:before_publish, %{
      event: :before_publish,
      doc: %{"type" => "task", "content" => content},
      dataset: @dataset,
      prev_doc: nil,
      ctx: %{}
    })
  end

  describe "empty title → hard stop (409)" do
    test "a create with no title halts the save" do
      assert {:error, {:halted, msg}} =
               create_task("qg-empty-1", %{"content" => base_content()})

      assert msg =~ "title"
    end

    test "a create with a whitespace-only title halts the save" do
      assert {:error, {:halted, msg}} =
               create_task("qg-empty-2", %{"title" => "   ", "content" => base_content()})

      assert msg =~ "title"
    end

    test "a halted save writes nothing" do
      {:error, {:halted, _}} = create_task("qg-empty-3", %{"content" => base_content()})
      assert {:error, :not_found} = Content.get_document("drafts.qg-empty-3", "task", @dataset)
    end
  end

  describe "zero acceptance_criteria on a fresh task → soft warn, still saves" do
    test "the task saves and a warning is emitted" do
      log =
        capture_log(fn ->
          assert {:ok, doc} =
                   create_task("qg-zero-1", %{
                     "title" => "A real task",
                     "content" => base_content()
                   })

          assert doc.title == "A real task"
        end)

      assert log =~ "zero acceptance_criteria"
      # It really persisted — no hard stop.
      assert {:ok, _} = Content.get_document("drafts.qg-zero-1", "task", @dataset)
    end

    test "an empty acceptance_criteria list also only warns" do
      log =
        capture_log(fn ->
          assert {:ok, _} =
                   create_task("qg-zero-2", %{
                     "title" => "Empty crit list",
                     "content" => base_content(%{"acceptance_criteria" => []})
                   })
        end)

      assert log =~ "zero acceptance_criteria"
    end
  end

  describe "malformed acceptance_criteria → reject (halt)" do
    test "a non-list acceptance_criteria halts" do
      assert {:halt, msg} =
               before_save(%{
                 "title" => "Bad crit",
                 "content" => base_content(%{"acceptance_criteria" => "not-a-list"})
               })

      assert msg =~ "acceptance_criteria"
    end

    test "a list with a non-map entry halts" do
      assert {:halt, msg} =
               before_save(%{
                 "title" => "Bad crit entries",
                 "content" =>
                   base_content(%{"acceptance_criteria" => [%{"criterion" => "ok"}, 42, "x"]})
               })

      assert msg =~ "criterion" or msg =~ "acceptance_criteria"
    end
  end

  describe "well-formed and partial-update paths stay smooth" do
    test "a well-formed task (title + one criterion) saves without a halt" do
      assert {:ok, doc} =
               create_task("qg-good-1", %{
                 "title" => "Ship the gate",
                 "content" =>
                   base_content(%{
                     "acceptance_criteria" => [
                       %{"criterion" => "gate exists", "met" => false, "evidence" => ""}
                     ]
                   })
               })

      assert doc.title == "Ship the gate"
    end

    test "a metadata-only update of a titled task is NOT blocked (title inherited)" do
      {:ok, _} =
        create_task("qg-upd-1", %{
          "title" => "Titled already",
          "content" =>
            base_content(%{
              "acceptance_criteria" => [%{"criterion" => "c", "met" => false}]
            })
        })

      # A patch that carries content but no title, and no criteria — must not
      # halt. The lifecycle change must be a LEGAL D7 transition (open →
      # blocked) — the Writer-seam transition gate (tlv) refuses a raw
      # open → in_progress (a claim is minted only by `bp task claim`), which
      # is not the concern under test here.
      assert {:ok, _} =
               Content.upsert_document(
                 "task",
                 %{
                   "doc_id" => "qg-upd-1",
                   "content" => base_content(%{"lifecycle_status" => "blocked"})
                 },
                 @dataset
               )
    end
  end

  describe "PortableDoc brief publish wall" do
    test "a task without a brief cannot publish" do
      assert {:halt, msg} = before_publish(base_content())
      assert msg =~ "task brief is required"
      assert msg =~ "bp task tui"
    end

    test "a PortableDoc v1 brief using TUI block types publishes" do
      brief = %{
        "version" => 1,
        "blocks" => [
          %{"type" => "heading", "level" => 2, "text" => "Purpose"},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Clear."}]},
          %{"type" => "list", "items" => ["One proof"]}
        ]
      }

      assert :ok = before_publish(base_content(%{"brief" => brief}))
    end

    test "a renderer-unknown block is rejected with the exact type" do
      brief = %{"version" => 1, "blocks" => [%{"type" => "bullet_list", "items" => ["x"]}]}
      assert {:halt, msg} = before_publish(base_content(%{"brief" => brief}))
      assert msg =~ "bullet_list"
      assert msg =~ "unsupported"
    end

    test "nested section blocks are checked too" do
      brief = %{
        "version" => 1,
        "blocks" => [
          %{"type" => "section", "blocks" => [%{"type" => "not-in-pdrender"}]}
        ]
      }

      assert {:halt, msg} = before_publish(base_content(%{"brief" => brief}))
      assert msg =~ "not-in-pdrender"
    end
  end
end
