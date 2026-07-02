defmodule BarkparkCloud.GitHub.Client do
  @moduledoc """
  The GitHub SEAM (gh-2). Every call the control plane makes to GitHub on behalf
  of a team's installed GitHub App goes through this behaviour, so the
  `BarkparkCloud.GitHub` context never talks to `api.github.com` directly. The
  concrete client is selected from config (`GitHub.client/0`), exactly like
  `Billing.Gateway` and the `:studio_link_http_client` transport:

    * `GitHub.Fake` in dev/test — an in-memory, deterministic, inspectable double
      (no network, no App key, no cost).
    * `GitHub.Real` in prod ONCE a human wires the App id + private key — builds
      the App-JWT (RS256) → installation-token exchange → REST call shapes and
      sends them over the verified-TLS `:httpc` transport seam.

  This is what lets the whole "deploy from a template into the user's own GitHub"
  path be built and tested with ZERO real GitHub credentials: tests run every
  context path through `Fake`, and `Real`'s request/JWT shapes are asserted
  without a byte leaving the box. No real GitHub call is ever made in the suite
  (HUMAN-LAST — the App credentials are a later human gate).

  ## The identity every callback carries

  A GitHub App acts on a repo through a short-lived INSTALLATION TOKEN, minted
  from an App-JWT for a specific `installation_id`. So the mutating callbacks
  take the `installation_id` (the stable numeric handle GitHub assigns when the
  App is installed on an account) and the concrete client resolves a fresh
  installation token internally per call — the context never handles the token.

  ## Callbacks

    * `get_installation/1`          — read an installation's public metadata
      (its `account_login`). The validation primitive: a real installation
      resolves, an unknown/uninstalled id returns `{:error, :not_found}`. This is
      how the connect endpoint proves the id the browser handed back is real.
    * `exchange_installation_token/1` — mint a short-lived installation access
      token for `installation_id` (App-JWT → `POST /app/installations/:id/access_tokens`).
    * `create_repo/3`              — create a repo (`name`, `private?`) under the
      installation's account.
    * `push_files/4`               — create-or-update a batch of files on a repo
      (`repo_full_name`, `[%{path, content}]`, commit `message`).
    * `register_webhook/4`         — register a push webhook on a repo
      (`repo_full_name`, delivery `url`, HMAC `secret`).
    * `list_repos/1`               — list the repos the installation can access.

  Every callback returns `{:ok, _} | {:error, term}` so call sites pattern-match
  rather than rescue.
  """

  @typedoc "The stable numeric installation handle GitHub assigns (as a string or integer)."
  @type installation_id :: String.t() | integer()

  @typedoc "A short-lived installation access token (`ghs_…`)."
  @type installation_token :: String.t()

  @typedoc "A repo's `owner/name` full name."
  @type repo_full_name :: String.t()

  @typedoc "A file to write: an absolute-in-repo `path` and its raw (unencoded) `content`."
  @type file :: %{path: String.t(), content: String.t()}

  @doc """
  Read an installation's public metadata. Returns `{:ok, %{account_login: login}}`
  for a live installation, `{:error, :not_found}` for an unknown / uninstalled
  id. This is the connect-time validation primitive.
  """
  @callback get_installation(installation_id) ::
              {:ok, %{account_login: String.t()}} | {:error, term}

  @doc """
  Mint a short-lived installation access token for `installation_id`. Returns
  `{:ok, token}` or `{:error, term}`.
  """
  @callback exchange_installation_token(installation_id) ::
              {:ok, installation_token} | {:error, term}

  @doc """
  Create a repo named `name` (`private?` true/false) under the installation's
  account. Returns `{:ok, %{"full_name" => …}}` (the created repo) or an error.
  """
  @callback create_repo(installation_id, name :: String.t(), private? :: boolean()) ::
              {:ok, map()} | {:error, term}

  @doc """
  Create-or-update `files` on `repo_full_name` in one commit `message` batch.
  Returns `{:ok, %{pushed: n}}` or `{:error, term}`.
  """
  @callback push_files(
              installation_id,
              repo_full_name,
              files :: [file()],
              message :: String.t()
            ) :: {:ok, map()} | {:error, term}

  @doc """
  Register a push webhook on `repo_full_name` delivering to `url`, signed with
  `secret`. Returns `{:ok, %{"id" => …}}` or `{:error, term}`.
  """
  @callback register_webhook(
              installation_id,
              repo_full_name,
              url :: String.t(),
              secret :: String.t()
            ) :: {:ok, map()} | {:error, term}

  @doc "List the repos `installation_id` can access. Returns `{:ok, [repo_map]}` or an error."
  @callback list_repos(installation_id) :: {:ok, [map()]} | {:error, term}
end
