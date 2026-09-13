defmodule Barkpark.Seeds.Clean do
  @moduledoc """
  The clean seed profile (`BARKPARK_SEED_PROFILE=clean`) — what a fresh
  `bp setup` install gets: the Default tenancy scope, an admin token, and one
  welcome paper. NO demo schemas, NO demo documents, NO `barkpark-dev-token`,
  NO EDItEUR/Thema codelists (those serve onixedit, which is not in the clean
  plugin set). Plugin schemas (paper/mediaAsset/mediaCollection under
  `BARKPARK_PLUGINS=bulldocs,media`) land via the Bootstrap tail in
  `Barkpark.Seeds.run/1`.

  Every step is guarded for idempotence at the seed level — entrypoint.sh
  re-runs the seed on EVERY container start, so a re-run must mint no second
  token and never clobber a user-edited welcome paper.
  """

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Seeds.AdminTokenMintError

  @welcome_slug "welcome"

  @welcome_blocks [
    %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Welcome to Barkpark"},
    %{
      "id" => "p1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "value" =>
            "This is a paper — Barkpark's first-class document. Papers live in the " <>
              "Bulldocs plugin and render here, in the TUI, and at /papers/welcome."
        }
      ]
    },
    %{
      "id" => "p2",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "value" =>
            "Your media library is at Studio → Media. Everything else starts empty on purpose."
        }
      ]
    },
    %{
      "id" => "code1",
      "type" => "code",
      "value" =>
        "bp doc ls            # list documents\n" <>
          "bp paper             # papers from the terminal\n" <>
          "bp media             # media library\n" <>
          "bp setup --help      # reconfigure"
    }
  ]

  @doc "Seed the clean profile under `scope` (from `Shared.ensure_default_scope/0`)."
  def seed(scope) do
    IO.puts("Seed profile: clean (papers + media)")
    seed_welcome_paper(scope)
    bootstrap_admin_token(scope)
  end

  # ── Welcome paper ────────────────────────────────────────────────────────

  # Skip-if-present, NOT upsert-always: a re-seed (every container start)
  # must never clobber user edits to the welcome paper. The probe is scoped
  # to the write's tenant, mirroring upsert_paper's pre-write lookup contract.
  defp seed_welcome_paper(scope) do
    case Content.get_paper(@welcome_slug, scope.dataset, workspace_id: scope.workspace_id) do
      nil ->
        {:ok, _doc} =
          Content.upsert_paper(
            %{
              "slug" => @welcome_slug,
              "dataset" => scope.dataset,
              "workspace_id" => scope.workspace_id,
              "project_id" => scope.project_id,
              "blocks" => @welcome_blocks,
              "style" => "article"
            },
            # bypass_wall (charter D26 audit): boot-time seed of curated host
            # content into a FRESH install — the E3 tag registry is empty here,
            # so no label set could pass, and a seed failure would break first
            # boot. Explicit, audited exemption.
            bypass_wall: true
          )

        IO.puts("Seeded welcome paper (/papers/#{@welcome_slug})")

      _existing ->
        IO.puts("Welcome paper already present — skipping.")
    end
  end

  # ── Admin token bootstrap ────────────────────────────────────────────────

  # Resolution order:
  #   1. an unrevoked admin token already exists → skip (idempotence for
  #      entrypoint.sh re-seeds);
  #   2. BARKPARK_SEED_ADMIN_TOKEN set (the `bp setup` path — the CLI
  #      generates bp_admin_<base64url 24B> and threads it here) → hash+store
  #      what we received, NEVER echo it;
  #   3. neither (manual `BARKPARK_SEED_PROFILE=clean mix ecto.reset`) →
  #      generate one and print it ONCE in the store-it-now banner. Raw
  #      tokens are SHA256-hashed at rest — unrecoverable after that print.
  defp bootstrap_admin_token(scope) do
    if admin_token_present?(scope) do
      IO.puts("Admin token already present — skipping token bootstrap.")
    else
      case System.get_env("BARKPARK_SEED_ADMIN_TOKEN") do
        raw when is_binary(raw) and raw != "" ->
          mint_admin_token!(raw, scope)
          IO.puts("Admin token installed from BARKPARK_SEED_ADMIN_TOKEN (not echoed).")

        _ ->
          raw = "bp_admin_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
          mint_admin_token!(raw, scope)
          print_token_banner(raw)
      end
    end
  end

  # Fenced to the SEED SCOPE's workspace, matching what mint_admin_token! below
  # writes (create_token/5 stamps scope.workspace_id). `Auth.list_tokens/2`
  # returns secret-free MAPS — `has_permission?/2` reads `:permissions` and the
  # guard reads `:revoked_at`, both of which the select list carries.
  defp admin_token_present?(scope) do
    scope.workspace_id
    |> Auth.list_tokens(scope.dataset)
    |> Enum.any?(fn t -> is_nil(t.revoked_at) and Auth.has_permission?(t, "admin") end)
  end

  # NOT a hard `{:ok, _} =` match. `api_tokens.token_hash` is unique-indexed and
  # `admin_token_present?/1` above requires `revoked_at IS NULL`, so a FIXED
  # BARKPARK_SEED_ADMIN_TOKEN that was later REVOKED arrives here with a hash
  # that is already on a row: `create_token/5` declares
  # `unique_constraint(:token_hash)`, hands back `{:error, %Ecto.Changeset{}}`,
  # and the old match raised `MatchError` out of a private function — a stack
  # trace that named neither the revoked token nor a way forward, taking the
  # seed's caller down with it under `set -euo pipefail`.
  #
  # The refusal itself is CORRECT and stays (the gate is closed by decision:
  # pds-bl-up-seed-remint-crash-after-revoke). Only the SHAPE changes — a named
  # error that says what collided and what to do.
  defp mint_admin_token!(raw, scope) do
    case Auth.create_token(
           raw,
           "admin (bp setup)",
           scope.dataset,
           ["read", "write", "admin"],
           scope.workspace_id
         ) do
      {:ok, token} ->
        token

      {:error, %Ecto.Changeset{} = changeset} ->
        raise AdminTokenMintError, message: mint_failure_message(changeset)
    end
  end

  # The collision is the expected failure and gets the operator instructions;
  # anything else is reported verbatim rather than mislabelled as a revoke.
  defp mint_failure_message(changeset) do
    if duplicate_token_hash?(changeset) do
      """
      Admin token mint REFUSED: BARKPARK_SEED_ADMIN_TOKEN names a credential
      this box has already minted and then REVOKED.

      api_tokens.token_hash is unique, and the revoked row still holds this
      token's hash. A revoked credential is never re-minted — that is the
      bootstrap gate closing, by decision, not a bug.

      Do ONE of these, then re-run the mint:
        * unset BARKPARK_SEED_ADMIN_TOKEN (check ~/.barkpark/.env — it is
          sourced wholesale) and let a fresh token be generated and printed
          once; or
        * set BARKPARK_SEED_ADMIN_TOKEN to a DIFFERENT value.

      The raw token is NOT echoed here, on purpose.
      """
    else
      """
      Admin token mint FAILED — #{inspect(changeset.errors)}.

      This is NOT the revoked-token collision; the seed refused before writing
      any credential.
      """
    end
  end

  defp duplicate_token_hash?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:token_hash, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp print_token_banner(raw) do
    IO.puts("""
    ==========================================================
      Admin token (shown ONCE — store it now):

          #{raw}

      Connect with:  bp setup --target connect \\
                       --server #{connect_url()} --token <token>
    ==========================================================\
    """)
  end

  @doc """
  The box's ACTUAL base URL — what the store-it-now banner tells the owner to
  point `bp setup --target connect` at.

  A hardcoded `http://localhost:4000` is a copy-pasteable instruction that
  cannot work on any box not on the default port (observed against a `:47016`
  personal box) — the same defect class as a vacuous green.

  NOT `Endpoint.url/0`: `config/runtime.exs` pins the PUBLIC `url:` port to
  80/443 because every prod box is proxy-fronted, so `url/0` renders
  "http://localhost" on a personal box. The port a client must actually dial is
  the LISTEN port in the `:http` config, which `runtime.exs` sets from `PORT` in
  every env — the same `PORT` `bin/barkpark` exports.

  Public (not `defp`) so the URL can be read back WITHOUT minting a token:
  `PORT=47016 mix run -e 'IO.puts(Barkpark.Seeds.Clean.connect_url())'` is the
  whole non-default-port proof.
  """
  def connect_url do
    url = BarkparkWeb.Endpoint.config(:url) || []
    http = BarkparkWeb.Endpoint.config(:http) || []
    "#{url[:scheme] || "http"}://#{url[:host] || "localhost"}:#{http[:port] || 4000}"
  end
end
