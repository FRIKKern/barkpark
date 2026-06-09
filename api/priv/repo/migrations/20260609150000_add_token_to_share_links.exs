defmodule Barkpark.Repo.Migrations.AddTokenToShareLinks do
  @moduledoc """
  P7 item-share UX: store the link's raw token so the link is STABLE and
  RE-COPYABLE (Google-Docs-style — the same link persists; the Studio popover
  shows it every time), not shown once then unrecoverable.

  Tradeoff (deliberate, documented): a share link is a shareable-by-design
  secret in a self-hosted/LAN context — anyone who can read this column can
  already read the shared content directly — so plaintext storage here is an
  acceptable cost for the persistent-link UX. `token_hash` is kept (the resolve
  lookup + unique index are unchanged).
  """
  use Ecto.Migration

  def change do
    alter table(:share_links) do
      add :token, :string
    end
  end
end
