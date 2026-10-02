defmodule BarkparkWeb.WriteAdmissionMutateTest do
  # A held managed instance must refuse a real HTTP mutation and leave rows,
  # revisions and the admission journal unchanged (Barkdown C083). Not async:
  # it enables write admission for the whole VM while it runs.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.Repo

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-admission-http-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    journal = Path.join(root, "admission.dets")
    instance = "http-fixture-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    {:ok, gate} = Admission.start_link(journal: journal, instance_id: instance, initialize: true)
    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate}
  end

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", Jason.encode!(%{"mutations" => mutations}))
  end

  defp create(id), do: %{"create" => %{"_id" => id, "_type" => "post", "title" => id}}

  test "an open instance admits and settles a real mutation", %{conn: conn, gate: gate} do
    resp = mutate(conn, [create("admitted-1")])
    assert resp.status in 200..299, resp.resp_body
    assert {:ok, _} = Content.get_document("drafts.admitted-1", "post", "test")
    assert Admission.status(gate).pending == 0
    assert Admission.status(gate).phase == :open
  end

  test "a held instance refuses the mutation and changes nothing", %{conn: conn, gate: gate} do
    {:ok, _} = Content.create_document("post", %{"_id" => "before", "title" => "before"}, "test")
    rows = Repo.aggregate(Content.Document, :count)
    {:ok, before} = Content.get_document("drafts.before", "post", "test")

    {:ok, :held, hold} = hold(gate, "switch")
    sequence = Admission.status(gate).sequence

    resp =
      mutate(conn, [
        create("refused-1"),
        %{"patch" => %{"id" => "drafts.before", "set" => %{"title" => "changed"}}}
      ])

    assert resp.status == 503
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "storage_unavailable"
    assert body["error"]["reason"] == "write_admission_admission_closed"

    assert Repo.aggregate(Content.Document, :count) == rows
    assert {:error, _} = Content.get_document("drafts.refused-1", "post", "test")
    assert {:ok, after_hold} = Content.get_document("drafts.before", "post", "test")
    assert after_hold.rev == before.rev
    assert after_hold.title == before.title
    # The journal did not move: no admission was journaled for the refused write.
    assert Admission.status(gate).sequence == sequence
    assert Admission.status(gate).phase == :held

    # Direct context writes are refused at the same door, not only HTTP.
    assert {:error, {:write_admission, :admission_closed}} =
             Content.create_document("post", %{"_id" => "ctx", "title" => "ctx"}, "test")

    assert {:error, {:write_admission, :admission_closed}} =
             Content.publish_document("before", "post", "test")

    release(gate, hold)
    resp = mutate(conn, [create("after-1")])
    assert resp.status in 200..299, resp.resp_body
  end

  # The test process owns the hold: begin_hold/reopen are synchronous calls that
  # journal to DETS before replying, so there is no message to race. A spawned
  # holder re-published the replies against assert_receive's 100ms default,
  # which CI load outran (main run 36574063509, task-5381a4e7a1724185). The
  # owner only needs to hold no write of its own when the hold begins.
  defp hold(gate, operation),
    do: Admission.begin_hold(gate, operation, Admission.status(gate).generation)

  defp release(gate, ticket), do: assert(Admission.reopen(gate, ticket) == :ok)
end
