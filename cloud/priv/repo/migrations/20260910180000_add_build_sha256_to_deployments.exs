defmodule BarkparkCloud.Repo.Migrations.AddBuildSha256ToDeployments do
  @moduledoc """
  deploy-reliability (dr-w12-bl-box-build-writes-no-digest, charter D188): THE
  BOX-BUILD RELEASE GETS A RECEIPT.

  ## What no row could say before

  `artifact_sha256` is the digest of the UPLOADED TARBALL, stamped by
  `Sites.Deploy.store_artifact/3` on the upload path alone. In prod that is 6
  rows of 30,633. The other 30,627 are `source = "box-build"` and carry NULL —
  including every live deployment that closed a superseded revision — and
  `deploy/site-deploy.sh` wrote `.bp-prebuilt-sha256` only on the PREBUILT arm,
  so the box kept no receipt either. A wrong artifact could be served and no
  instrument anywhere would disagree with itself.

  ## What this column is, and what it is NOT

  `build_sha256` is the sha256 of the RELEASE TREE the box measured through its
  own `current` symlink after SWITCH committed — the bytes Caddy is serving.

  It is NOT an identity key and must never be used as one: one `content_rev`
  produced FOUR distinct artifacts on this fleet, so the build is not
  reproducible and no digest here is a content address. It answers exactly one
  question — "are the bytes that went live the bytes this run staged" — and the
  answer is computed by comparing it against the box's INDEPENDENT STAGE-time
  reading, which `Sites.Deploy` refuses the deployment over when they disagree.

  ## Why it is a separate column from `artifact_sha256`

  Two reasons, either sufficient. (1) DIFFERENT QUANTITIES: `artifact_sha256`
  digests a compressed tarball, this digests an extracted tree; putting both in
  one column would make the column's own values incomparable. (2) THE REAPER:
  `Registry`'s prebuilt-upload sweep is
  `source == "prebuilt" and is_nil(artifact_sha256)` — "minted but never
  uploaded". Widening what writes `artifact_sha256` is the one change that could
  silently redefine that predicate, and it is not made here.

  ## Why this ALTER is safe on the live table, and why there is no backfill

  Nullable, no default: a catalog-only `ALTER`, no table rewrite, no per-row
  work — the same argument `20260910140000_add_deferral_pacing_to_deployments`
  made for this table. Every pre-existing row stays NULL, which is the honest
  reading: nobody measured those bytes, and a backfill would claim a receipt
  that was never taken. No index — the readers are per-row.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :build_sha256, :string
    end
  end
end
