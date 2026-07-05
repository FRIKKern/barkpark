defmodule BarkparkCloud.Vercel.Client do
  @moduledoc """
  The Vercel SEAM (task-4e4a53b101a97051). Every call the control plane makes to
  the Vercel platform API goes through this behaviour, so the
  `BarkparkCloud.Vercel` context never talks to `api.vercel.com` directly. The
  concrete client is selected from config (`Vercel.client/0`), exactly like the
  `GitHub.Client` seam it mirrors:

    * `Vercel.Fake` in dev/test — an in-memory, deterministic, inspectable double
      (no network, no platform token, no cost).
    * `Vercel.Real` in prod ONCE a human wires the platform token — builds the
      REST call shapes (create project + env → upload files → create deployment
      → transfer-request) and sends them over the verified-TLS `:httpc`
      transport seam.

  This powers the zero-paste "Deploy to Vercel" handoff: the control plane
  deploys the template WITH all env values already set (they never ride a URL),
  then hands the user a `vercel.com/claim-deployment?code=…` link — the user
  claims the fully configured project into their own account, no form.

  ## Callbacks

    * `deploy_project/3` — create a project (with its environment variables set
      server-side), upload the app files, and create a production deployment.
      One coarse operation: the multi-call dance is a Real-client concern; the
      context and the fake reason about the OUTCOME.
    * `create_transfer_code/1` — mint a claim/transfer code for a project
      (valid 24h on Vercel's side). Separate from deploy so an expired code can
      be re-minted without re-deploying.

  Every callback returns `{:ok, _} | {:error, term}` so call sites pattern-match
  rather than rescue.
  """

  @typedoc "A file to deploy: an in-project relative `path` and its raw `content`."
  @type file :: %{path: String.t(), content: String.t()}

  @typedoc "An env var to set on the project (stored encrypted on Vercel, all targets)."
  @type env_var :: %{key: String.t(), value: String.t()}

  @doc """
  Create the project named `name` with `env_vars` installed, upload `files`, and
  create a production deployment. Returns
  `{:ok, %{project_id: id, deployment_url: url}}` or `{:error, term}`.
  """
  @callback deploy_project(name :: String.t(), files :: [file()], env_vars :: [env_var()]) ::
              {:ok, %{project_id: String.t(), deployment_url: String.t()}} | {:error, term}

  @doc """
  Mint a claim/transfer code for `project_id`. Returns `{:ok, code}` or
  `{:error, term}`. Codes expire after 24 hours on Vercel's side.
  """
  @callback create_transfer_code(project_id :: String.t()) ::
              {:ok, String.t()} | {:error, term}
end
