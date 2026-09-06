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

  defp mint_admin_token!(raw, scope) do
    {:ok, _token} =
      Auth.create_token(
        raw,
        "admin (bp setup)",
        scope.dataset,
        ["read", "write", "admin"],
        scope.workspace_id
      )
  end

  defp print_token_banner(raw) do
    IO.puts("""
    ==========================================================
      Admin token (shown ONCE — store it now):

          #{raw}

      Connect with:  bp setup --target connect \\
                       --server http://localhost:4000 --token <token>
    ==========================================================\
    """)
  end
end
