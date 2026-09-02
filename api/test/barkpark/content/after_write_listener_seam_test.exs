defmodule Barkpark.Content.AfterWriteListenerSeamTest do
  @moduledoc """
  task-9dd19a906209fb29 — the INVERTED after-write listener seam.

  `Barkpark.Content.WriteScope.fire_after/3` used to call
  `Barkpark.Workers.FindabilityPosttest.enqueue_after/1` directly — a
  kernel→feature edge (`content → workers`) the boundary gate reports as
  wrong-direction. The call now goes through `config :barkpark,
  :after_write_listeners`, which config.exs (the composition root) populates and
  content only READS. This file proves the seam carries the behaviour and
  nothing else:

    * INSTALLED — the shipped config names the findability worker, and a
      walled-type (paper) PUBLISH through `Content` still enqueues the job
      (the E5 self-test survives the move);
    * EMPTY — with the listener list `[]` the same publish succeeds and
      enqueues NOTHING (restoring the direct call reds this one: the mutation
      proof for "content no longer imports the worker");
    * ADVISORY — a raising listener and an exiting listener are logged and
      dropped; the publish still returns `{:ok, _}` and the listeners AFTER
      them still run (the write already committed);
    * SELF-GATING — a non-walled type publish through the installed seam still
      enqueues nothing (`enqueue_after/2`'s own gate is intact).

  NOT async: the seam is one global `Application` env key.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Workers.FindabilityPosttest

  @dataset "after_write_listener_seam_test"
  @seam_key :after_write_listeners

  setup do
    original = Application.get_env(:barkpark, @seam_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, @seam_key)
        value -> Application.put_env(:barkpark, @seam_key, value)
      end
    end)

    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{"name" => "note", "title" => "Note", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp labeled_content(main_tag) do
    Barkpark.LabelFixtures.register_tags!(@dataset, [main_tag, "secondary-axis"])

    %{
      "description" => "A non-trivial description for the after-write seam wall.",
      "tags" => [
        %{"tag" => main_tag, "strength" => 90, "rationale" => "The primary axis of the probe."},
        %{
          "tag" => "secondary-axis",
          "strength" => 40,
          "rationale" => "A secondary axis so the tag count sits inside the norm."
        }
      ]
    }
  end

  defp publish_paper!(id, main_tag) do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => "Seam Probe #{id}", "content" => labeled_content(main_tag)},
        @dataset
      )

    Content.publish_document(id, "paper", @dataset)
  end

  describe "INSTALLED — the shipped config carries the findability worker" do
    test "config.exs names {FindabilityPosttest, :enqueue_after} and content never does" do
      listeners = Application.get_env(:barkpark, @seam_key)
      assert {FindabilityPosttest, :enqueue_after} in listeners

      # The kernel side holds no reference to the worker module: the seam is
      # the ONLY road. (Comments may still carry the name as search vocabulary;
      # this reads code, not prose.)
      source = File.read!(Path.join(File.cwd!(), "lib/barkpark/content/write_scope.ex"))

      code_lines =
        source
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))

      refute Enum.any?(code_lines, &String.contains?(&1, "Barkpark.Workers.")),
             "write_scope.ex names a Barkpark.Workers module in code — the edge is back"
    end

    test "a walled-type PUBLISH through Content still enqueues the self-test", ctx do
      id = "seam-installed-#{ctx.line}"
      assert {:ok, published} = publish_paper!(id, "seamfindable")
      assert published.status == "published"

      assert_enqueued(
        worker: FindabilityPosttest,
        args: %{"doc_id" => id, "type" => "paper", "dataset" => @dataset}
      )
    end

    test "SELF-GATING — a non-walled type publish enqueues nothing through the seam" do
      {:ok, _} =
        Content.create_document("note", %{"_id" => "seam-note", "title" => "N"}, @dataset)

      assert {:ok, _} = Content.publish_document("seam-note", "note", @dataset)
      assert [] = all_enqueued(worker: FindabilityPosttest)
    end
  end

  describe "EMPTY — the seam is the only road" do
    test "with no listeners the publish succeeds and NOTHING is enqueued", ctx do
      Application.put_env(:barkpark, @seam_key, [])

      id = "seam-empty-#{ctx.line}"
      assert {:ok, published} = publish_paper!(id, "seamsilent")
      assert published.status == "published"

      assert [] = all_enqueued(worker: FindabilityPosttest),
             "a job was enqueued with the listener list EMPTY — content is calling the " <>
               "worker directly again (the content → workers edge is back)"
    end

    test "an unset key (deleted env) behaves like an empty list", ctx do
      Application.delete_env(:barkpark, @seam_key)

      id = "seam-unset-#{ctx.line}"
      assert {:ok, _} = publish_paper!(id, "seamunset")
      assert [] = all_enqueued(worker: FindabilityPosttest)
    end
  end

  describe "ADVISORY — a broken listener never fails the write" do
    test "a raising listener, an exiting listener and garbage are dropped; later listeners run",
         ctx do
      test_pid = self()

      Application.put_env(:barkpark, @seam_key, [
        fn _payload -> raise "listener boom" end,
        fn _payload -> exit(:listener_exit) end,
        :not_a_listener,
        {Barkpark.Nonexistent.Module, :nope},
        fn payload -> send(test_pid, {:seam_reached, payload.event, payload.doc.doc_id}) end,
        {FindabilityPosttest, :enqueue_after}
      ])

      id = "seam-advisory-#{ctx.line}"

      log =
        capture_log(fn ->
          assert {:ok, published} = publish_paper!(id, "seamsturdy")
          assert published.status == "published"
        end)

      assert log =~ "listener boom"
      assert log =~ "listener_exit"

      # The listeners after the broken ones still ran, in order.
      assert_received {:seam_reached, :after_publish, ^id}

      assert_enqueued(
        worker: FindabilityPosttest,
        args: %{"doc_id" => id, "type" => "paper", "dataset" => @dataset}
      )
    end
  end
end
