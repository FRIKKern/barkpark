defmodule Barkpark.Repo.Migrations.AddHandedOutAtToChatExecutionLeases do
  @moduledoc """
  task-b1e2f61ca03df99b: the first time a host poll is handed a lease
  (`ChatHosts.next_commands/1`). A same-key resend puts a reused lease back on
  the in-memory queue only when no host was ever handed it: a host that ran it
  and then forgot it (its queue listing went empty on a server restart) would
  otherwise run it a second time.

  Additive only. One nullable column with no default, so Postgres adds it
  without rewriting the table. Every existing row reads NULL, never handed
  out, as the server knew it before this column. No backfill, and no existing
  row is touched.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_execution_leases) do
      add :handed_out_at, :utc_datetime_usec
    end
  end
end
