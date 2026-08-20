defmodule Barkpark.Repo.Migrations.AddCloudSandboxIdToChatSessions do
  use Ecto.Migration

  @cloud_sandbox_constraint :chat_sessions_cloud_sandbox_id_check

  # The session-scoped Cloud sandbox binding (Connectors wave 14, charter
  # D136/D137/D139). The :cloud execution profile runs each turn as an isolated
  # one-shot in a Vercel Sandbox; when it keeps a sandbox alive across turns it
  # emits its opaque sandbox id ONCE, and the Barkpark Chat Session row becomes
  # the durable owner of that binding so the next one-shot turn resumes the SAME
  # sandbox. A COLUMN (not a sibling table) is decided: a 1:1 binding that
  # inherits `owner_workspace_id`'s tenant seal for free. NEVER a transcript
  # store — only the opaque id lives here (the .jsonl boundary stays, D136).
  #
  # Unlike write-once `provider_session_id`, this legitimately RESETS on sandbox
  # expiry (D139), so no historical backfill: an existing/self-hosted session
  # simply reads NULL (no binding). The non-empty check mirrors
  # `chat_sessions_provider_session_id_check` so a blank string can never masquer-
  # ade as a real sandbox id.
  def up do
    alter table(:chat_sessions) do
      add :cloud_sandbox_id, :string
    end

    create constraint(:chat_sessions, @cloud_sandbox_constraint,
             check: "cloud_sandbox_id IS NULL OR length(btrim(cloud_sandbox_id)) > 0"
           )
  end

  def down do
    drop constraint(:chat_sessions, @cloud_sandbox_constraint)

    alter table(:chat_sessions) do
      remove :cloud_sandbox_id
    end
  end
end
