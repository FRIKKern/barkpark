defmodule Barkpark.Content.WriteScopeFailClosedTest do
  @moduledoc """
  Fail-closed contract for WriteScope dataset resolution
  (felix-w26-bl-write-scope-swallow-nil).

  On origin/main, `resolve_dataset_id_for_write/2` collapsed EVERY
  `{:error, _}` from `Tenancy.get_or_create_dataset/2` to `nil` — a refused
  dataset resolution silently landed `dataset_id=NULL` (silent accept of an
  invalid slug + split-brain visibility between strict dataset_id readers and
  NULL-tolerant string readers). This suite pins the replacement contract:

    * a format-invalid `dataset` URL segment on POST /v1/data/mutate/:dataset
      is a LOUD 422 `validation_failed` with the changeset messages re-keyed
      under `details["dataset"]`, and the whole batch rolls back — no
      documents row persists;
    * the `{:error, :dataset_not_found}` insert-ok/reload-nil race is retried
      exactly once, then surfaces as `{:error, :conflict}` → the existing 409
      envelope (never 422 — not the caller's fault — and never nil);
    * the LEGIT-nil arms survive: nil project (incl. the wykb
      projectless-workspace NEVER-WORSE case) and a non-binary dataset still
      stamp nothing rather than erroring.

  Mutation-proven: reverting the resolver's error arms to `_ -> nil` reds the
  tests in this file (the fail-before run in the task ledger quotes it).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.{Document, Errors, WriteScope}

  @invalid_dataset "Not-Valid"

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    :ok
  end

  defp do_mutate(conn, dataset, body) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{dataset}", Jason.encode!(body))
  end

  describe "POST /v1/data/mutate/<format-invalid dataset> (the reachable defect path)" do
    test "422 validation_failed with details[\"dataset\"], and the whole batch rolls back",
         %{conn: conn} do
      body = %{
        "mutations" => [
          %{"create" => %{"_id" => "fc-1", "_type" => "post", "title" => "first"}},
          %{"create" => %{"_id" => "fc-2", "_type" => "post", "title" => "second"}}
        ]
      }

      resp = do_mutate(conn, @invalid_dataset, body)

      assert resp.status == 422
      body_json = Jason.decode!(resp.resp_body)
      assert body_json["error"]["code"] == "validation_failed"

      # The changeset messages are RE-KEYED under "dataset" — the key the
      # caller actually sent (the row's :slug field is an internal name).
      dataset_details = body_json["error"]["details"]["dataset"]
      assert is_list(dataset_details) and dataset_details != []

      # Batch rollback: NO documents row persisted — neither under the invalid
      # dataset string nor under the mutated ids.
      assert Repo.aggregate(
               from(d in Document, where: d.dataset == @invalid_dataset),
               :count
             ) == 0

      assert {:error, :not_found} =
               Content.get_document("drafts.fc-1", "post", @invalid_dataset)

      assert {:error, :not_found} =
               Content.get_document("drafts.fc-2", "post", @invalid_dataset)
    end
  end

  describe "put_scope_attrs/2 fail-closed error shapes" do
    test "an invalid dataset slug is {:error, {:invalid_dataset, details}} — never a NULL stamp" do
      assert {:error, {:invalid_dataset, details}} =
               Content.put_scope_attrs(%{"dataset" => @invalid_dataset}, [])

      assert %{"dataset" => [_ | _]} = details
    end

    test "a valid dataset slug still stamps the resolved dataset_id" do
      assert {:ok, attrs} = Content.put_scope_attrs(%{"dataset" => "production"}, [])
      assert is_binary(attrs["dataset_id"])
      assert is_binary(attrs["workspace_id"])
      assert is_binary(attrs["project_id"])
    end
  end

  describe "legit-nil arms preserved (NEVER-WORSE)" do
    test "non-binary dataset stamps no dataset_id and does not error" do
      assert {:ok, attrs} = Content.put_scope_attrs(%{"dataset" => 42}, [])
      refute Map.has_key?(attrs, "dataset_id")
    end

    test "missing dataset key stamps no dataset_id and does not error" do
      assert {:ok, attrs} = Content.put_scope_attrs(%{"title" => "t"}, [])
      refute Map.has_key?(attrs, "dataset_id")
    end

    test "workspace-only scope on a projectless workspace stays nil-project/nil-dataset_id (wykb)" do
      ws = create_workspace!()

      assert {:ok, attrs} =
               Content.put_scope_attrs(
                 %{"dataset" => @invalid_dataset},
                 workspace_id: ws.id
               )

      # The workspace has NO projects → project_id resolves nil → the resolver
      # never runs, even against an invalid dataset string. The wykb NEVER-WORSE
      # arm: workspace stamped, nothing else, no error.
      assert attrs["workspace_id"] == ws.id
      refute Map.has_key?(attrs, "project_id")
      refute Map.has_key?(attrs, "dataset_id")
    end
  end

  describe "the :dataset_not_found race retries exactly once" do
    test "two consecutive misses surface {:error, :conflict} after exactly one retry" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      resolver = fn _project_id, _slug ->
        Agent.update(counter, &(&1 + 1))
        {:error, :dataset_not_found}
      end

      assert {:error, :conflict} =
               WriteScope.resolve_dataset_id_with_retry("proj-id", "race-ds", resolver)

      assert Agent.get(counter, & &1) == 2, "must call the resolver exactly twice (one retry)"
    end

    test "a first miss that recovers on retry returns the resolved id" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      resolver = fn _project_id, _slug ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> {:error, :dataset_not_found}
          _ -> {:ok, %Barkpark.Tenancy.Dataset{id: "recovered-id"}}
        end
      end

      assert {:ok, "recovered-id"} =
               WriteScope.resolve_dataset_id_with_retry("proj-id", "race-ds", resolver)

      assert Agent.get(counter, & &1) == 2
    end

    test "the persistent race maps to the existing 409 conflict envelope, never 422" do
      env = Errors.to_envelope({:error, :conflict})
      assert env.status == 409
      assert env.code == "conflict"
    end
  end

  describe "the invalid_dataset envelope" do
    test "reuses the canonical validation_failed code at 422" do
      env = Errors.to_envelope({:error, {:invalid_dataset, %{"dataset" => ["is bad"]}}})
      assert env.status == 422
      assert env.code == "validation_failed"
      assert env.details == %{"dataset" => ["is bad"]}
    end
  end
end
