defmodule Barkpark.ChatHosts.RegisteredHostReadinessTest do
  @moduledoc """
  Regression cover for the two live-proof findings (task-5419892277cea01c):

    1. `ChatHosts.resolve/2` (via `get_host/2`) used to crash on a nil
       `workspace_id` — a `:global`-scoped chat session carries
       `owner_workspace_id == nil`, which reached `h.workspace_id == ^nil` and
       Ecto refuses that comparison, 500-ing every registered-host send.

    2. `RegisteredHost.safe_capabilities?` rejected the very `operations` /
       `task_hands` provider-readiness fields that
       `Runtime.registered_provider_ready/2` demands — so a real host could
       never persist a capabilities map that passes the dispatch gate.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.Tenancy

  describe "get_host/2 + resolve/2 nil-scope safety (finding 1)" do
    test "a nil workspace_id fails closed instead of raising an Ecto nil comparison" do
      host_id = Ecto.UUID.generate()

      # Before the guard these calls raised
      # `ArgumentError: comparing … with nil is forbidden` inside Recorder.init.
      assert is_nil(ChatHosts.get_host(nil, host_id))
      assert {:error, :host_not_found} = ChatHosts.resolve(nil, host_id)

      # A nil host id is equally unsafe and equally fail-closed.
      assert is_nil(ChatHosts.get_host(Ecto.UUID.generate(), nil))
      assert {:error, :host_not_found} = ChatHosts.resolve(Ecto.UUID.generate(), nil)
    end

    test "the binary workspace path still resolves a live host (guard did not narrow it)" do
      %{host: host} = enroll_ready_host()

      assert {:ok, resolved} = ChatHosts.resolve(host.workspace_id, host.id)
      assert resolved.id == host.id
    end
  end

  describe "safe capabilities persist operations/task_hands (finding 2)" do
    test "an enrollment carrying the full provider readiness is a VALID changeset" do
      changeset =
        RegisteredHost.enrollment_changeset(%RegisteredHost{}, %{
          workspace_id: Ecto.UUID.generate(),
          name: "laptop",
          enrollment_hash: <<0>>,
          enrollment_expires_at: DateTime.utc_now(),
          capabilities: full_readiness_capabilities()
        })

      assert changeset.valid?,
             "operations/task_hands readiness must be storable: #{inspect(changeset.errors)}"
    end

    test "a heartbeat carrying operations/task_hands persists through the wire" do
      %{host: host} = enroll_ready_host()

      assert {:ok, updated} =
               ChatHosts.heartbeat(host, %{capabilities: full_readiness_capabilities()})

      stored = Repo.get!(RegisteredHost, host.id)
      claude = stored.capabilities["providers"]["claude"]
      assert claude["task_hands"] == true
      assert "send_turn" in claude["operations"]
      assert updated.capabilities["providers"]["claude"]["task_hands"] == true
    end

    test "a secret-shaped provider field is still rejected" do
      changeset =
        RegisteredHost.heartbeat_changeset(%RegisteredHost{}, %{
          capabilities: %{
            "protocol_version" => 1,
            "providers" => %{
              "claude" => %{"installed" => true, "auth_ready" => true, "token" => "sk-secret"}
            }
          }
        })

      refute changeset.valid?
    end
  end

  describe "end-to-end: a wire-stored host passes the dispatch readiness gate" do
    test "Runtime.open/2 for a registered host gets past readiness once operations/task_hands are stored" do
      %{host: host} = enroll_ready_host()

      opts = %{
        session_id: Ecto.UUID.generate(),
        execution_target: "registered_host",
        workspace_id: host.workspace_id,
        execution_host_id: host.id,
        mode: "plan",
        session_opts: %{}
      }

      # readiness reads the STORED capabilities (not a test fake). Passing means
      # {:ok, ref}; failing readiness would be {:error, {:provider_not_ready, _}}
      # or {:error, {:provider_protocol_incompatible, _}}.
      assert {:ok, ref} = Runtime.open("claude", opts)
      assert ref.execution_host_id == host.id
    end
  end

  # An enrolled + online host whose STORED capabilities carry the full provider
  # readiness the dispatch gate requires.
  defp enroll_ready_host do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rhr-#{suffix}", name: "RHR #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "laptop-#{suffix}",
        approved_roots: [System.tmp_dir!()],
        capabilities: full_readiness_capabilities()
      })

    {:ok, enrolled} =
      ChatHosts.enroll(issued.enrollment_token, %{capabilities: full_readiness_capabilities()})

    %{
      host: Repo.get!(RegisteredHost, issued.host.id),
      credential: enrolled.credential,
      workspace: ws
    }
  end

  defp full_readiness_capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{
        "claude" => %{
          "installed" => true,
          "auth_ready" => true,
          "operations" => ~w(send_turn steer interrupt answer_approval close),
          "task_hands" => true
        }
      }
    }
  end
end
