defmodule BarkparkCloud.Repo.Migrations.AddContentBindingVerdictToSites do
  @moduledoc """
  ssw8-persist-binding-verdict (site-spawner W8, charter D73) — the create-time
  binding verdict gets a HOME on the row.

  `POST /v1/sites` already READS the binding back with the site's own public-read
  token and answers 201 with a `content_binding` verdict — but that verdict was
  EPHEMERAL: it lived only in the create response. Every later surface (list,
  detail, console, `bp`) read `content_bound`, which was literally
  `not is_nil(read_token_encrypted)` — "a token was minted", which every
  content-bound site has, so the field discriminated NOTHING. A site whose
  binding was PROVEN readable and a site created before the verification existed
  were byte-identical on the wire.

  Two columns, and the enum is the load-bearing half:

    * `content_binding_verdict` — NOT NULL, default `never_checked`. Four honest
      values: `bound` (the site read its own content), `unverified` (the read
      could not be performed or interpreted), `not_applicable` (a container site
      — there is no binding to check), `never_checked` (nobody ever looked).
      NEVER-CHECKED IS ITS OWN VALUE, not a nullable `bound`: a nullable boolean
      whose NULL is read as "probably fine" is exactly the un-backed field this
      migration exists to retire.
    * `content_binding_checked_at` — nullable. When the verdict was WRITTEN by a
      real check. NULL for `never_checked` and `not_applicable`, because in
      neither case did anything actually read anything.

  BACKFILL: every existing row becomes `never_checked` by the column default.
  That is the only honest reading — no site on this box has had its binding
  verified and recorded, including the ones created after the create-time read
  landed (the verdict was thrown away). A later successful check overwrites it.
  """
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :content_binding_verdict, :string, null: false, default: "never_checked"
      add :content_binding_checked_at, :utc_datetime_usec
    end
  end
end
