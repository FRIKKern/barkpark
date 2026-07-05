defmodule BarkparkCloud.Vercel do
  @moduledoc """
  The Vercel platform context (task-4e4a53b101a97051) — the zero-paste "Deploy
  to Vercel" handoff. Instead of sending the user to Vercel's env form (which
  can only prefill NAMES — the six values had to be pasted by hand, and secrets
  can never ride a URL), the control plane deploys the template itself via the
  Vercel API with every env value already installed, then mints a
  claim/transfer code: the user clicks `vercel.com/claim-deployment?code=…`,
  picks their team, and receives the fully configured, already-live project.

  ## HUMAN-LAST / fail-closed

  No real platform token exists in the repo. `configured?/0` reports whether
  the token is wired (env, prod-only); the deploy endpoint refuses with a 503
  `feature_not_configured` when absent — the SPA then falls back to the classic
  `vercel.com/new/clone` copy-block handoff, which keeps working forever. The
  app BOOTS regardless; nothing here raises on missing credentials. In dev/test
  the client is the in-memory `Vercel.Fake`, so the whole deploy/claim path is
  provable at €0.

  ## Store

  The deploy outcome lives on the barkpark row: `vercel_project_id` +
  `vercel_deploy_url` plaintext (non-secret display state), the claim code
  ENCRYPTED (`Registry.Vault` — it grants project ownership) plus its mint
  stamp. A re-deploy click on an already-deployed instance re-mints ONLY the
  code (Vercel codes expire after 24h) — never a duplicate project.
  """

  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Templates.AppFiles

  # Vercel transfer codes are valid 24h; treat ours as stale slightly earlier so
  # a link we hand out is never seconds from death.
  @claim_ttl_ms 23 * 60 * 60 * 1000

  @doc """
  The configured `Vercel.Client`. Resolved at call time (config-at-call-time, so
  a runtime.exs override wins). Defaults to `Vercel.Fake` — a missing config is
  the safe in-memory double, never a real Vercel call.
  """
  @spec client() :: module()
  def client do
    config() |> Keyword.get(:client, BarkparkCloud.Vercel.Fake)
  end

  @doc """
  Is the platform token wired to actually talk to Vercel right now? The deploy
  endpoint gates on this and 503s `feature_not_configured` when false — the
  feature is flagged off, not half-broken.
  """
  @spec configured?() :: boolean()
  def configured? do
    present?(config()[:token])
  end

  @doc """
  Deploy `bp`'s template to Vercel with its bootstrap env installed, and mint a
  claim code. Idempotent on the project: an already-deployed instance re-mints
  ONLY the transfer code. Returns `{:ok, state}` (see `state/1`) or:

    * `{:error, :no_bootstrap}`   — no content bootstrap stored (template-less launch)
    * `{:error, :not_deployable}` — the template ships no standalone app tree
    * `{:error, term}`            — the client call failed (surfaced to the 502)
  """
  @spec deploy_for(Barkpark.t()) :: {:ok, map()} | {:error, term}
  def deploy_for(%Barkpark{vercel_project_id: pid} = bp) when is_binary(pid) and pid != "" do
    with {:ok, code} <- client().create_transfer_code(pid),
         {:ok, bp} <- persist(bp, %{claim_code: code}) do
      {:ok, state(bp)}
    end
  end

  def deploy_for(%Barkpark{} = bp) do
    with {:ok, boot} <- bootstrap_of(bp),
         {:ok, files} <- app_files(bp),
         {:ok, deployed} <- client().deploy_project(project_name(bp), files, env_vars(boot)),
         {:ok, code} <- client().create_transfer_code(deployed.project_id),
         {:ok, bp} <-
           persist(bp, %{
             project_id: deployed.project_id,
             deploy_url: deployed.deployment_url,
             claim_code: code
           }) do
      {:ok, state(bp)}
    end
  end

  @doc """
  The non-secret-by-default deploy state for the dashboard/ready screen:

      %{configured:, deployed:, deployment_url:, claim_url:}

  `claim_url` is the `vercel.com/claim-deployment?code=…` link (the SPA appends
  its own `returnUrl`), present only while the stored code is fresh (< 23h) —
  a stale code renders as `nil` so the SPA offers a re-mint instead of a dead
  link. Owner-facing only: the route this rides is team-admin-gated, same
  custody as the bootstrap read token.
  """
  @spec state(Barkpark.t()) :: map()
  def state(%Barkpark{} = bp) do
    %{
      configured: configured?(),
      deployed: present?(bp.vercel_project_id),
      deployment_url: bp.vercel_deploy_url,
      claim_url: claim_url(bp)
    }
  end

  ## Internals ───────────────────────────────────────────────────────────────

  defp claim_url(%Barkpark{vercel_claim_encrypted: nil}), do: nil

  defp claim_url(%Barkpark{} = bp) do
    fresh? =
      case bp.vercel_claim_minted_at do
        %DateTime{} = at -> DateTime.diff(DateTime.utc_now(), at, :millisecond) < @claim_ttl_ms
        _ -> false
      end

    with true <- fresh?,
         {:ok, code} <- Vault.decrypt(bp.vercel_claim_encrypted) do
      "https://vercel.com/claim-deployment?code=" <> URI.encode_www_form(code)
    else
      _ -> nil
    end
  end

  defp bootstrap_of(bp) do
    case BarkparkCloud.Registry.reveal_bootstrap(bp) do
      {:ok, nil} -> {:error, :no_bootstrap}
      {:ok, boot} -> {:ok, boot}
      :error -> {:error, :no_bootstrap}
    end
  end

  defp app_files(bp) do
    case AppFiles.render(bp.template || "", bp.slug || "barkpark-site") do
      {:ok, files} -> {:ok, files}
      {:error, :unknown_template} -> {:error, :not_deployable}
    end
  end

  # The bootstrap env map (BARKPARK_API_URL/TOKEN/WORKSPACE/PROJECT/DATASET/
  # WEBHOOK_SECRET) IS the contract the templates read — install it verbatim.
  defp env_vars(%{env: env}) when is_map(env) do
    env
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> %{key: to_string(k), value: to_string(v)} end)
  end

  defp env_vars(_), do: []

  # Vercel project names are unique per team — suffix the slug with the row id's
  # head so two teams' "blog" instances never collide in OUR platform team.
  defp project_name(%Barkpark{} = bp) do
    suffix = bp.id |> to_string() |> String.replace("-", "") |> binary_part(0, 6)
    AppFiles.to_package_name("#{bp.slug}-#{suffix}")
  end

  defp persist(bp, attrs) do
    changes =
      %{}
      |> maybe_put(:vercel_project_id, attrs[:project_id])
      |> maybe_put(:vercel_deploy_url, attrs[:deploy_url])
      |> Map.put(:vercel_claim_encrypted, Vault.encrypt(attrs.claim_code))
      |> Map.put(:vercel_claim_minted_at, DateTime.utc_now())

    bp |> Barkpark.vercel_changeset(changes) |> Repo.update()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(value), do: is_binary(value) and value != ""

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])
end
