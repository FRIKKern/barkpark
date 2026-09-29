defmodule BarkparkWeb.WriteAdmissionBlockOpsTest do
  # C083 slice 8: a block op refused by the door answers 503 `storage_unavailable`,
  # the transient every other write door gives, not 422 `invalid_op`. A client must be
  # able to tell "the instance is held, retry" from "your op is wrong".
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission

  # Set in config/test.exs.
  @ingest "barkpark-test-ingest-token"

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)
    ws = Barkpark.TenancyFixtures.default_workspace_id!()
    Barkpark.Auth.create_token("held-ops-write", "w", "test", ["read", "write"], ws)

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-held-ops-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "heldops-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: "held-ops-paper",
          blocks: [%{"type" => "paragraph", "text" => "seed", "id" => "b1"}],
          style: "article"
        })
      )

    {:ok, _doc} =
      Content.create_document(
        "post",
        %{
          "_id" => "held-ops-post",
          "title" => "Held ops",
          "blocks" => [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "first"}]
            }
          ]
        },
        "test"
      )

    %{gate: gate}
  end

  defp as(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp append(id, value),
    do: %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => value}]
      }
    }

  defp paper_rev, do: get_in(Content.get_paper("held-ops-paper").content, ["rev"])

  defp refused!(resp) do
    assert resp.status == 503, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "storage_unavailable"
    assert body["error"]["reason"] == "write_admission_admission_closed"
  end

  test "held refuses a paper op, a paper op batch and a document op with 503; reopen admits",
       %{gate: gate} do
    rev = paper_rev()
    {:ok, post} = Content.get_document("drafts.held-ops-post", "post", "test")
    {:ok, :held, hold} = hold(gate, "switch")

    scoped_conn()
    |> as(@ingest)
    |> post("/v1/plugins/bulldocs/papers/held-ops-paper/ops", Jason.encode!(append("one", "one")))
    |> refused!()

    scoped_conn()
    |> as(@ingest)
    |> post(
      "/v1/plugins/bulldocs/papers/held-ops-paper/ops",
      Jason.encode!(%{"ifRev" => rev, "ops" => [append("two", "two"), append("three", "three")]})
    )
    |> refused!()

    scoped_conn()
    |> as("held-ops-write")
    |> post(
      "/v1/data/doc/test/post/held-ops-post/ops",
      Jason.encode!(%{"op" => append("four", "four"), "ifRev" => post.rev})
    )
    |> refused!()

    {:ok, unchanged} = Content.get_document("drafts.held-ops-post", "post", "test")
    assert unchanged.rev == post.rev

    assert paper_rev() == rev
    assert Admission.status(gate).phase == :held

    release(hold)

    resp =
      scoped_conn()
      |> as(@ingest)
      |> post(
        "/v1/plugins/bulldocs/papers/held-ops-paper/ops",
        Jason.encode!(append("after", "after"))
      )

    assert resp.status == 200, resp.resp_body
  end

  # The hold belongs to a process that holds no write.
  defp hold(gate, operation) do
    parent = self()

    holder =
      spawn(fn ->
        result = Admission.begin_hold(gate, operation, Admission.status(gate).generation)
        send(parent, {:hold, self(), result})

        receive do
          :release ->
            {:ok, _, ticket} = result
            send(parent, {:released, Admission.reopen(gate, ticket)})
        end
      end)

    receive do
      {:hold, ^holder, {:ok, phase, _ticket}} -> {:ok, phase, holder}
    after
      5_000 -> flunk("hold did not answer")
    end
  end

  defp release(holder) do
    send(holder, :release)
    assert_receive {:released, :ok}, 5_000
  end
end
