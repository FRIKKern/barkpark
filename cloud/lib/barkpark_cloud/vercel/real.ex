defmodule BarkparkCloud.Vercel.Real do
  @moduledoc """
  The real `BarkparkCloud.Vercel.Client` — it builds the ACTUAL Vercel platform
  API request shapes and sends them over the injected verified-TLS transport.
  Selected in prod ONLY once a human wires the platform token (HUMAN-LAST: no
  real credential exists in the repo, so this module is exercised purely through
  its pure builders in the suite — no byte ever reaches `api.vercel.com`).

  ## The claim-deployments dance (docs/deployments/claim-deployments)

  `deploy_project/3` is the documented sequence:

    1. `POST /v11/projects` — create the project with `environmentVariables`
       set server-side (`type: "encrypted"`, all targets). Values NEVER ride a
       URL; they travel once, in this authenticated request body.
    2. `POST /v2/files` per file — content-addressed upload (`x-vercel-digest`
       is the file's SHA1, the body its raw bytes).
    3. `POST /v13/deployments` — create the production deployment from the
       uploaded file manifest (`{file, sha, size}` triples).

  `create_transfer_code/1` is `POST /v9/projects/:id/transfer-request` — the
  returned code (24h validity) parameterises the user-facing
  `vercel.com/claim-deployment?code=…` URL.

  A team-scoped platform token needs `?teamId=` on every call; `team_id` config
  is optional and appended when present.

  ## Injectable HTTP client — €0 in tests, no new dep

  Same seam as `GitHub.Real` / `Billing.StripeGateway`: `request/1` resolves a
  1-arity client fn from config (`http_client: &m.f/1`) and calls it with the
  `%{method, url, headers, body}` map. In prod that is `Billing.HttpClient`
  (Erlang `:httpc`, verified TLS). In dev/test there is no client, so any
  callback that would hit the wire returns `{:error, :http_client_not_configured}`
  — it can NEVER silently call Vercel. The pure request builders are the
  assertion seam.
  """
  @behaviour BarkparkCloud.Vercel.Client

  @api_base "https://api.vercel.com"
  @user_agent "barkpark-cloud"

  @impl true
  def deploy_project(name, files, env_vars)
      when is_binary(name) and is_list(files) and is_list(env_vars) do
    with {:ok, token} <- token(),
         {:ok, project} <- request(create_project_request(token, name, env_vars)),
         project_id when is_binary(project_id) <- project["id"] || {:error, :unexpected_response},
         :ok <- upload_files(token, files),
         {:ok, deployment} <- request(create_deployment_request(token, name, project_id, files)) do
      case deployment do
        %{"url" => url} when is_binary(url) ->
          {:ok, %{project_id: project_id, deployment_url: "https://" <> url}}

        _ ->
          {:error, :unexpected_response}
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :unexpected_response}
    end
  end

  @impl true
  def create_transfer_code(project_id) when is_binary(project_id) do
    with {:ok, token} <- token(),
         {:ok, decoded} <- request(transfer_request_request(token, project_id)) do
      case decoded do
        %{"code" => code} when is_binary(code) -> {:ok, code}
        _ -> {:error, :unexpected_response}
      end
    end
  end

  ## Pure request builders — the assertion seam (NO network) ─────────────────

  @doc """
  `POST /v11/projects` with the env vars installed at create time: each var is
  `type: "encrypted"` (Vercel stores it sealed) across all three targets. PURE.
  """
  def create_project_request(token, name, env_vars) do
    body = %{
      name: name,
      framework: "nextjs",
      environmentVariables:
        Enum.map(env_vars, fn %{key: k, value: v} ->
          %{key: k, value: v, target: ["production", "preview", "development"], type: "encrypted"}
        end)
    }

    build_request(:post, "/v11/projects", token, Jason.encode!(body), "application/json")
  end

  @doc "`POST /v2/files` — content-addressed raw upload for one file. PURE."
  def upload_file_request(token, content) do
    req = build_request(:post, "/v2/files", token, content, "application/octet-stream")
    %{req | headers: req.headers ++ [{"x-vercel-digest", sha1(content)}]}
  end

  @doc """
  `POST /v13/deployments` — a production deployment from the uploaded manifest.
  Each entry references its file by SHA1 + size (already uploaded via
  `/v2/files`). PURE.
  """
  def create_deployment_request(token, name, project_id, files) do
    body = %{
      name: name,
      project: project_id,
      target: "production",
      files:
        Enum.map(files, fn %{path: path, content: content} ->
          %{file: path, sha: sha1(content), size: byte_size(content)}
        end),
      projectSettings: %{framework: "nextjs"}
    }

    build_request(:post, "/v13/deployments", token, Jason.encode!(body), "application/json")
  end

  @doc "`POST /v9/projects/:id/transfer-request` — mint the 24h claim code. PURE."
  def transfer_request_request(token, project_id) do
    build_request(
      :post,
      "/v9/projects/" <> URI.encode(project_id) <> "/transfer-request",
      token,
      Jason.encode!(%{}),
      "application/json"
    )
  end

  @doc """
  Assemble one request map for the transport seam. The optional `team_id` config
  is appended as `?teamId=` — a team-scoped platform token fails without it. PURE
  given config.
  """
  def build_request(method, path, token, body, content_type) do
    %{
      method: method,
      url: @api_base <> path <> team_query(path),
      headers: [
        {"Authorization", "Bearer " <> token},
        {"User-Agent", @user_agent},
        {"Content-Type", content_type}
      ],
      body: body
    }
  end

  @doc "Lowercase hex SHA1 — Vercel's content address for `/v2/files`. PURE."
  def sha1(content), do: :crypto.hash(:sha, content) |> Base.encode16(case: :lower)

  ## Internals ───────────────────────────────────────────────────────────────

  defp upload_files(token, files) do
    Enum.reduce_while(files, :ok, fn %{content: content}, :ok ->
      case request(upload_file_request(token, content)) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp team_query(_path) do
    case config()[:team_id] do
      team_id when is_binary(team_id) and team_id != "" -> "?teamId=" <> URI.encode(team_id)
      _ -> ""
    end
  end

  # Fails closed (no raise) when the platform token is unset, so an accidental
  # invocation of Real without credentials returns an error instead of crashing.
  defp token do
    case config()[:token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_configured}
    end
  end

  # Resolve the injected HTTP client and perform the request. NEVER reaches the
  # wire in tests (no client configured → fail closed). On a 2xx, decode the JSON
  # body; otherwise surface the status + body.
  defp request(req) do
    case http_client() do
      fun when is_function(fun, 1) ->
        with {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(req),
             {:ok, decoded} <- decode_body(body) do
          {:ok, decoded}
        else
          {:ok, %{status: status, body: body}} -> {:error, {:vercel_http_error, status, body}}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_vercel_response, other}}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  # /v2/files answers an empty body on success — treat it as an empty map.
  defp decode_body(""), do: {:ok, %{}}
  defp decode_body(body), do: Jason.decode(body)

  defp http_client, do: config()[:http_client]
  defp config, do: Application.get_env(:barkpark_cloud, BarkparkCloud.Vercel, [])
end
