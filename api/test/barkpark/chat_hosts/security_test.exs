defmodule Barkpark.ChatHosts.SecurityTest do
  use ExUnit.Case, async: true

  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost, Security}

  test "raw enrollment and host credentials are represented only by hashes" do
    secret = Security.mint_secret()
    hash = Security.hash_secret(secret)

    assert is_binary(secret)
    assert byte_size(secret) >= 43
    assert byte_size(hash) == 32
    refute hash == secret
    assert Security.secret_matches?(secret, hash)
    refute Security.secret_matches?(secret <> "x", hash)
  end

  test "registered hosts reject relative roots and secret-shaped capabilities" do
    attrs = %{
      workspace_id: Ecto.UUID.generate(),
      name: "laptop",
      enrollment_hash: :crypto.strong_rand_bytes(32),
      enrollment_expires_at: DateTime.add(DateTime.utc_now(), 60),
      approved_roots: ["relative/path"],
      capabilities: %{"token" => "must-not-cross-boundary"}
    }

    changeset = RegisteredHost.enrollment_changeset(%RegisteredHost{}, attrs)

    refute changeset.valid?
    assert "must be absolute" in errors_on(changeset).approved_roots
    assert "must contain only non-secret readiness metadata" in errors_on(changeset).capabilities
  end

  test "registered hosts reject unknown nested readiness keys" do
    attrs = %{
      workspace_id: Ecto.UUID.generate(),
      name: "laptop",
      enrollment_hash: :crypto.strong_rand_bytes(32),
      enrollment_expires_at: DateTime.add(DateTime.utc_now(), 60),
      approved_roots: [System.tmp_dir!()],
      capabilities: %{
        "protocol_version" => 1,
        "providers" => %{
          "codex" => %{
            "installed" => true,
            "auth_ready" => true,
            "auth" => "opaque-session-material"
          }
        }
      }
    }

    changeset = RegisteredHost.enrollment_changeset(%RegisteredHost{}, attrs)

    refute changeset.valid?
    assert "must contain only non-secret readiness metadata" in errors_on(changeset).capabilities
  end

  test "execution leases validate provider, epoch, and cursor fences" do
    changeset =
      ExecutionLease.changeset(%ExecutionLease{}, %{
        host_id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        provider: "other",
        epoch: 0,
        command_key: "cmd-1",
        last_cursor: -1,
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).provider
    assert "must be greater than 0" in errors_on(changeset).epoch
    assert "must be greater than or equal to 0" in errors_on(changeset).last_cursor
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
