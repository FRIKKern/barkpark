defmodule Barkpark.StudioChat.Runtime.CodexSessionTerminateTest do
  @moduledoc """
  Teardown of a codex Session must revoke the task-hands credential even when the
  port close raises (task-95b4b28a56583b1c — the twin of task-2f44ed9d10be629f).

  `reap_port/1` used to run `if Port.info(port), do: (… Port.close(port); kill …)`
  and `terminate/2` wrapped the WHOLE body in one rescue arm. That is a
  check-then-act: `Port.info/1` answers nil once the port is closed, so it is a
  membership test, and the port can die inside the window before the close, which
  then raises badarg. The whole-body rescue swallowed that raise AND skipped
  everything after it — the OS-process kill (the runaway-provider hazard GH #6681
  exists to stop) and `cleanup_task_token/1`, which is the only caller of
  `Auth.revoke_token/1` on this path. The credential outlived the session.

  An ALREADY-CLOSED port reproduces the raced port exactly: `Port.close/1` answers
  the identical `ArgumentError` badarg. No clock, no sleep, no lottery — the raise
  IS the condition, so the test states the condition.

  MEASURED CAVEAT, recorded so nobody reads more into these tests than they say:
  the LITERAL pre-fix shape passes them, because its own `if Port.info(port)`
  check suppresses the close on a dead port. That is the finding, not a gap — the
  membership test never prevented the leak, it only made the leak unreachable by
  any deterministic test, which is why the sole symptom was a load-correlated
  flake. Dropping the check is what converts an untestable race into the
  always-exercised path. The mutation these tests DO catch is the one the row
  names: putting the rescue back around the whole body.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth.ApiToken
  alias Barkpark.StudioChat.Runtime.Codex.Session

  defp dead_port do
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    Port.close(port)
    port
  end

  defp task_token! do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("codex-task-hands-" <> Ecto.UUID.generate()),
        label: "codex-task-hands",
        dataset: "test",
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    token
  end

  test "terminate revokes the task-hands token even when the port close raises" do
    port = dead_port()
    token = task_token!()

    # Preconditions: this port is the raising kind, and the credential is live.
    assert_raise ArgumentError, fn -> Port.close(port) end
    assert is_nil(Repo.get!(ApiToken, token.id).revoked_at)

    assert :ok = Session.terminate(:normal, %{port: port, task_token: token})

    refute is_nil(Repo.get!(ApiToken, token.id).revoked_at),
           "the task-hands credential outlived a teardown whose port close raised"
  end

  test "terminate is total when there is no task token" do
    assert :ok = Session.terminate(:normal, %{port: dead_port(), task_token: nil})
    assert :ok = Session.terminate(:normal, %{port: dead_port()})
  end
end
