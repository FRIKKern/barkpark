defmodule Barkpark.Plugins.Forms.Web.SubmissionController do
  @moduledoc """
  The anonymous form endpoint for hosted sites (task-71082f5541c13b53, N-08):

      POST /v1/plugins/forms/w/:workspace/p/:project/d/:dataset/sites/:site/submissions

  The body is the form's fields, flat — exactly what an HTML `<form>` posts as
  `application/x-www-form-urlencoded`, or the same object as JSON. `bp_hp` is
  the honeypot input. `201 {"ok": true, "id": …}` means one `form_submission`
  document now exists in that workspace/project/dataset and nowhere else.

  ## Order of the gates, and why

    1. **Declared size** — a `content-length` over #{64 * 1024} bytes is a 413
       before anything else runs.
    2. **Per-address budget** — `Barkpark.RateLimiter.check/2` keyed on
       `RateLimiter.client_ip/1` (the trusted-proxy resolver, so a direct
       caller cannot rotate `x-forwarded-for` to mint budget), across every
       form on the box. Before the lookup, so probing for endpoints is metered.
    3. **Binding** — `Intake.resolve_endpoint/4`. Any miss is one uniform 404.
    4. **Origin** — the `Origin` header must equal one of the endpoint's
       `allowed_origins`. A missing header is refused: every browser sends one
       on a cross-origin POST, and this endpoint exists for browsers.
    5. **Honeypot** — a filled `bp_hp` gets the success shape and no write, so
       the trap stays invisible (the `BulldocsFormController` precedent).
    6. **Per-endpoint budget** — one bucket per site binding, so a flood from
       many addresses still cannot fill a dataset without bound.
    7. **Contract** — `Contract.sanitize_fields/2`: an unknown field is a 422,
       an oversized one a 413. Refused whole; nothing partial is stored.
    8. **Store** — `Intake.store/3`, which re-checks the contract in the writer.

  `Origin` is a browser-enforced binding, not authentication: a non-browser
  client can send any `Origin`. What bounds a non-browser client is gates 2
  and 6, and what bounds the blast radius is gate 3 — a post can only ever
  reach the one dataset whose endpoint document names that site.

  An `Authorization` header is ignored. No response carries a token, the
  endpoint document, or any id other than the new submission's.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Plugins.Forms.{Contract, Intake}
  alias Barkpark.RateLimiter

  @max_body_bytes 64 * 1024
  @honeypot "bp_hp"

  # Buckets, in the RateLimiter census's terms (capacity / refill_per_sec =
  # seconds to refill from empty — both hourly, 3600s, which is the
  # `@stale_after_ms` ceiling in `Barkpark.RateLimiter`, so a depleted bucket is
  # never pruned back to full early).
  @ip_capacity 20
  @ip_refill_per_sec 20 / 3600
  @endpoint_capacity 300
  @endpoint_refill_per_sec 300 / 3600
  @ip_retry_after max(1, ceil(1 / @ip_refill_per_sec))
  @endpoint_retry_after max(1, ceil(1 / @endpoint_refill_per_sec))

  def submit(conn, %{"workspace" => ws, "project" => proj, "dataset" => ds, "site" => site}) do
    with :ok <- declared_size(conn),
         :ok <- rate_limit(conn, {:forms_ip, RateLimiter.client_ip(conn)}, :ip),
         {:ok, binding} <- Intake.resolve_endpoint(ws, proj, ds, site),
         {:ok, origin} <- origin(conn, binding),
         raw = posted_fields(conn),
         :ok <- honeypot(raw),
         :ok <- rate_limit(conn, endpoint_key(binding), :endpoint),
         {:ok, fields} <- Contract.sanitize_fields(Map.delete(raw, @honeypot), binding.fields),
         {spam, reasons} = Intake.spam_signals(fields),
         {:ok, stored} <-
           Intake.store(binding, fields, %{
             spam: spam,
             spam_reasons: reasons,
             source: source(conn, origin)
           }) do
      conn |> put_status(201) |> json(%{ok: true, id: stored.doc_id})
    else
      {:honeypot} ->
        conn |> put_status(201) |> json(%{ok: true})

      {:error, :too_large_declared} ->
        envelope(conn, 413, "payload_too_large", "form body exceeds #{@max_body_bytes} bytes")

      {:error, {:rate_limited, retry_after}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> envelope(429, "rate_limited", "too many form submissions", %{retry_after: retry_after})

      {:error, :not_found} ->
        envelope(conn, 404, "not_found", "form endpoint not found")

      {:error, :origin} ->
        envelope(conn, 403, "forbidden", "this origin may not post to this form")

      {:error, {:unknown_fields, names}} ->
        envelope(conn, 422, "validation_failed", "unknown form fields", %{unknown_fields: names})

      {:error, {:too_large, detail}} ->
        envelope(conn, 413, "payload_too_large", "form submission too large: #{detail}")

      {:error, {:invalid, detail}} ->
        envelope(conn, 422, "validation_failed", "invalid form submission: #{detail}")

      {:error, {:schema_validation_failed, details}} ->
        envelope(conn, 422, "validation_failed", "invalid form submission", details)

      {:error, _} ->
        envelope(conn, 422, "validation_failed", "invalid form submission")
    end
  end

  defp envelope(conn, status, code, message, details \\ nil) do
    env =
      %{code: code, message: message}
      |> then(fn env -> if details, do: Map.put(env, :details, details), else: env end)
      |> Barkpark.Content.Errors.stamp(conn)

    conn
    |> put_status(status)
    |> json(%{ok: false, error: env})
  end

  # ── gates ──────────────────────────────────────────────────────────────────

  defp declared_size(conn) do
    case get_req_header(conn, "content-length") do
      [len | _] ->
        case Integer.parse(len) do
          {n, ""} when n > @max_body_bytes -> {:error, :too_large_declared}
          _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp rate_limit(conn, key, kind) do
    {capacity, refill, retry_after} =
      case kind do
        :ip -> {@ip_capacity, @ip_refill_per_sec, @ip_retry_after}
        :endpoint -> {@endpoint_capacity, @endpoint_refill_per_sec, @endpoint_retry_after}
      end

    case RateLimiter.check(RateLimiter.scoped_key(conn, key),
           capacity: capacity,
           refill_per_sec: refill
         ) do
      :ok -> :ok
      :rate_limited -> {:error, {:rate_limited, retry_after}}
    end
  end

  defp endpoint_key(b), do: {:forms_endpoint, b.workspace_id, b.project_id, b.dataset, b.site}

  defp origin(conn, binding) do
    with [raw | _] <- get_req_header(conn, "origin"),
         {:ok, origin} <- Contract.normalize_origin(raw),
         true <- origin in binding.allowed_origins do
      {:ok, origin}
    else
      _ -> {:error, :origin}
    end
  end

  # `body_params`, never `params`: Phoenix merges the PATH params into
  # `params`, so a posted field named `site` or `dataset` would be shadowed by
  # the URL instead of judged (and refused when unknown). A JSON body that is
  # not an object arrives as `%{"_json" => …}` and is refused as an unknown
  # field like any other.
  defp posted_fields(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp posted_fields(%Plug.Conn{body_params: %{} = body}), do: body
  defp posted_fields(_conn), do: %{}

  defp honeypot(raw) do
    case Map.get(raw, @honeypot) do
      v when is_binary(v) and v != "" -> {:honeypot}
      _ -> :ok
    end
  end

  defp source(conn, origin) do
    %{
      "origin" => origin,
      "referer" => first_header(conn, "referer"),
      "user_agent" => first_header(conn, "user-agent")
    }
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end
end
