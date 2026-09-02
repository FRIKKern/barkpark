defmodule Barkpark.CycleFleet.ReleaseCaptureAdapter do
  @moduledoc "Server-owned adapter boundary for immutable release-gate reader captures."

  @callback capture(map()) :: {:ok, %{String.t() => map()}} | {:error, term()}

  def capture(request) do
    adapter =
      Application.get_env(:barkpark, :cycle_release_capture_adapter, __MODULE__.Production)

    adapter.capture(request)
  end

  def public_smoke(request) do
    adapter =
      Application.get_env(:barkpark, :cycle_release_capture_adapter, __MODULE__.Production)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :public_smoke, 1),
      do: adapter.public_smoke(request),
      else: {:error, :public_release_smoke_unavailable}
  end

  defmodule Production do
    @moduledoc false
    @behaviour Barkpark.CycleFleet.ReleaseCaptureAdapter

    alias Barkpark.CycleFleet.ReleaseCaptureAdapter.BoundedHTTP

    @http_surfaces ~w(source_json public_html)
    @headless_surfaces ~w(cli task_board tui)
    @max_command_output_bytes 2_000_000

    @impl true
    def capture(request) do
      with :ok <- validate_request(request),
           {:ok, token} <- fetch_binary(:cycle_release_capture_token),
           {:ok, bp_path} <- fetch_absolute_path(:cycle_release_capture_bp_path),
           {:ok, http} <- capture_http(request, token),
           {:ok, headless} <- capture_headless(request, token, bp_path) do
        {:ok, Map.merge(http, headless)}
      end
    rescue
      _ -> {:error, :server_release_capture_failed}
    end

    def public_smoke(request) do
      expected_origin = BarkparkWeb.Endpoint.url()

      with {:ok, deployment_digest} <- fetch_binary(:release_deployment_digest),
           true <- digest?(deployment_digest),
           true <- request["deployment_digest"] == deployment_digest,
           true <- request["format"] == "cycle-release-public-smoke-request-v1",
           true <- request["canonical_origin"] == expected_origin,
           documents when is_list(documents) <- request["documents"],
           true <- Enum.map(documents, & &1["role"]) == ~w(campaign successor),
           true <- Enum.all?(documents, &valid_public_document_request?(&1, request)) do
        attempts = Enum.map(documents, &public_smoke_attempt(&1, request))
        result = %{"format" => "cycle-release-public-smoke-v1", "attempts" => attempts}

        if Enum.all?(attempts, &(&1["verdict"] == "pass")),
          do: {:ok, result},
          else: {:error, result}
      else
        _ -> {:error, :invalid_public_release_smoke_request}
      end
    end

    defp public_smoke_attempt(document, request) do
      base = %{
        "role" => document["role"],
        "document_id" => document["document_id"],
        "doc_id" => document["doc_id"],
        "url" => document["url"],
        "deployment_digest" => request["deployment_digest"],
        "redirect_count" => 0
      }

      case public_http_get(document["url"]) do
        {:ok, status, headers, body} ->
          text = String.downcase(body)

          pass =
            status == 200 and valid_content_type?(headers["content_type"], "public_html") and
              headers["x_barkpark_paper_revision"] == document["revision_id"] and
              headers["etag"] == ~s("sha256:#{document["content_digest"]}") and
              not String.contains?(body, ~s(id="paper-invalid")) and
              not String.contains?(body, "data-source-error=") and
              String.contains?(text, String.downcase(document["title"])) and
              release_markers?(text)

          Map.merge(base, %{
            "status" => status,
            "response_headers" =>
              Map.take(headers, ~w(content_type etag x_barkpark_paper_revision)),
            "byte_count" => byte_size(body),
            "response_digest" => digest(body),
            "verdict" => if(pass, do: "pass", else: "fail")
          })

        {:error, reason} ->
          Map.merge(base, %{"verdict" => "fail", "error" => inspect(reason)})
      end
    end

    defp valid_public_document_request?(document, request) do
      encoded = URI.encode(document["doc_id"], &URI.char_unreserved?/1)
      workspace = URI.encode(request["workspace_slug"], &URI.char_unreserved?/1)
      project = URI.encode(request["project_slug"], &URI.char_unreserved?/1)

      expected =
        request["canonical_origin"] <>
          "/w/#{workspace}/p/#{project}/papers/#{encoded}"

      document["url"] == expected and is_binary(document["revision_id"]) and
        digest?(document["content_digest"])
    rescue
      _ -> false
    end

    defp validate_request(request) do
      expected_origin = BarkparkWeb.Endpoint.url()
      deployment_digest = Application.get_env(:barkpark, :release_deployment_digest)

      if request["format"] == "cycle-release-capture-request-v1" and
           request["canonical_origin"] == expected_origin and
           is_map(request["readers"]) and map_size(request["readers"]) == 2 and
           digest?(deployment_digest) and request["deployment_digest"] == deployment_digest,
         do: :ok,
         else: {:error, :invalid_server_capture_request}
    end

    defp capture_http(request, token) do
      captures =
        for role <- ~w(campaign successor), surface <- @http_surfaces, into: %{} do
          reader = get_in(request, ["readers", role, surface])

          case http_get(reader, token, surface) do
            {:ok, status, headers, body} ->
              provenance =
                base_provenance(request, role, surface, reader)
                |> Map.merge(%{
                  "status" => status,
                  "redirect_count" => 0,
                  "response_headers" => headers,
                  "binary_digest" => request["deployment_digest"],
                  "parser_digest" => digest("barkpark-server-http-v1")
                })

              {"#{role}.#{surface}",
               %{"raw_bytes" => body, "producer" => "server_http", "provenance" => provenance}}

            {:error, reason} ->
              throw({:capture_error, reason})
          end
        end

      {:ok, captures}
    catch
      {:capture_error, reason} -> {:error, reason}
    end

    defp capture_headless(request, token, bp_path) do
      Enum.reduce_while(~w(campaign successor), {:ok, %{}}, fn role, {:ok, captures} ->
        reader = get_in(request, ["readers", role, "cli"])
        [_binary | args] = reader["argv"]

        env = [
          {"BARKPARK_URL", request["canonical_origin"]},
          {"BARKPARK_TOKEN", token}
        ]

        case bounded_cmd(bp_path, args, 30_000, env: env) do
          {output, 0} ->
            case decode_headless(output, request, role) do
              {:ok, role_captures} -> {:cont, {:ok, Map.merge(captures, role_captures)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {_output, _status} ->
            {:halt, {:error, :headless_capture_failed}}
        end
      end)
    end

    defp decode_headless(output, request, role) do
      with {:ok, envelope} <- Jason.decode(output),
           true <- envelope["format"] == "cycle-release-headless-capture-v1",
           true <- envelope["release_gate_id"] == request["release_gate_id"],
           true <- envelope["wave_revision"] == request["wave_revision"],
           true <- envelope["candidate_id"] == request["candidates"][role]["candidate_id"],
           true <- envelope["role"] == role,
           true <- envelope["source_url"] == request["readers"][role]["source_json"]["url"],
           readers when is_map(readers) <- envelope["readers"] do
        if Map.keys(readers) |> Enum.sort() != @headless_surfaces do
          throw(:invalid_headless_capture)
        end

        captures =
          Map.new(@headless_surfaces, fn surface ->
            capture = readers[surface]
            provenance = stringify_keys(capture["provenance"] || %{})
            expected = request["readers"][role][surface]

            unless provenance["argv"] == expected["argv"] and
                     exact_headless_profile?(surface, provenance) do
              throw(:invalid_headless_capture)
            end

            provenance =
              provenance
              |> Map.merge(base_provenance(request, role, surface, expected))
              |> Map.put("status", 0)
              |> Map.put("redirect_count", 0)

            producer = if surface == "tui", do: "server_tui", else: "server_cli"

            {"#{role}.#{surface}",
             %{
               "raw_bytes" => capture["raw_utf8"],
               "producer" => producer,
               "provenance" => provenance
             }}
          end)

        {:ok, captures}
      else
        _ -> {:error, :invalid_headless_capture}
      end
    catch
      :invalid_headless_capture -> {:error, :invalid_headless_capture}
    end

    defp exact_headless_profile?("cli", provenance),
      do:
        provenance["geometry"] == "120xunbounded" and
          provenance["theme"] == "evergreen-dark" and provenance["profile"] == "none"

    defp exact_headless_profile?("task_board", provenance),
      do:
        provenance["geometry"] == "120xunbounded" and
          provenance["theme"] == "task-board-dark" and provenance["profile"] == "ansi256"

    defp exact_headless_profile?("tui", provenance),
      do:
        provenance["geometry"] == "120xunbounded;measure=100" and
          provenance["theme"] == "evergreen-dark" and provenance["profile"] == "ansi256"

    defp http_get(%{"method" => "GET", "url" => url}, token, surface) do
      headers = [{"authorization", "Bearer " <> token}]

      case BoundedHTTP.get(url, headers, expected_content_type: content_type(surface)) do
        {:ok, status, response_headers, body} ->
          normalized = normalize_headers(response_headers)

          if status == 200 and valid_content_type?(normalized["content_type"], surface),
            do: {:ok, status, normalized, body},
            else: {:error, :invalid_http_capture_response}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp http_get(_, _token, _surface), do: {:error, :invalid_http_capture_request}

    defp public_http_get(url) when is_binary(url) do
      case BoundedHTTP.get(url, [], expected_content_type: "text/html") do
        {:ok, status, response_headers, body} ->
          normalized = normalize_headers(response_headers)
          {:ok, status, normalized, body}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp public_http_get(_), do: {:error, :invalid_public_release_smoke_request}

    defp valid_content_type?(value, "source_json") when is_binary(value),
      do: String.starts_with?(String.downcase(value), "application/json")

    defp valid_content_type?(value, "public_html") when is_binary(value),
      do: String.starts_with?(String.downcase(value), "text/html")

    defp valid_content_type?(_, _), do: false

    defp content_type("source_json"), do: "application/json"
    defp content_type("public_html"), do: "text/html"

    defp bounded_cmd(command, args, timeout, opts) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(command)},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            env: encode_command_env(Keyword.fetch!(opts, :env))
          ]
        )

      collect_command(port, System.monotonic_time(:millisecond) + timeout, [], 0)
    rescue
      _ -> {"", 126}
    end

    defp collect_command(port, deadline, chunks, size) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, data}} when size + byte_size(data) <= @max_command_output_bytes ->
          collect_command(port, deadline, [data | chunks], size + byte_size(data))

        {^port, {:data, _data}} ->
          close_command_port(port)
          {"", 125}

        {^port, {:exit_status, status}} ->
          {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
      after
        remaining ->
          close_command_port(port)
          {"", 124}
      end
    end

    defp encode_command_env(env) do
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)
    end

    # Reached on the two abort paths only (output over the cap, deadline blown) —
    # i.e. exactly when the capture child is behaving badly enough that assuming
    # it exits on stdin EOF is the assumption least likely to hold. Closing the
    # port signals the child nothing, so reap the OS process: `PortReaper.reap/1`
    # reads the os_pid while the port is open, closes it, then SIGKILLs.
    defp close_command_port(port), do: Barkpark.PortReaper.reap(port)

    defp normalize_headers(headers) do
      Map.new(headers, fn {name, value} ->
        key = name |> to_string() |> String.downcase() |> String.replace("-", "_")
        {key, normalize_header_value(value)}
      end)
    end

    defp normalize_header_value(value) when is_binary(value), do: value

    defp normalize_header_value(value) when is_list(value) do
      if List.ascii_printable?(value),
        do: List.to_string(value),
        else: Enum.map_join(value, ", ", &to_string/1)
    end

    defp normalize_header_value(value), do: to_string(value)

    defp base_provenance(request, role, surface, reader) do
      %{
        "release_gate_id" => request["release_gate_id"],
        "wave_revision" => request["wave_revision"],
        "candidate_id" => request["candidates"][role]["candidate_id"],
        "role" => role,
        "surface" => surface,
        "request" => reader,
        "deployment_digest" => request["deployment_digest"]
      }
    end

    defp fetch_binary(key) do
      case Application.get_env(:barkpark, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _ -> {:error, {:missing_release_capture_config, key}}
      end
    end

    defp fetch_absolute_path(key) do
      with {:ok, path} <- fetch_binary(key),
           true <- Path.type(path) == :absolute and File.regular?(path) do
        {:ok, path}
      else
        _ -> {:error, {:invalid_release_capture_path, key}}
      end
    end

    defp stringify_keys(map),
      do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

    defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

    defp digest?(value),
      do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

    defp release_markers?(text),
      do: Enum.all?(~w(503 42 291 170 current superseded -11 +11), &String.contains?(text, &1))
  end

  defmodule BoundedHTTP do
    @moduledoc false

    @default_body_limit 2_000_000
    @default_timeout 15_000

    @doc false
    def get(url, headers, opts \\ []) when is_binary(url) and is_list(headers) do
      body_limit = Keyword.get(opts, :body_limit, @default_body_limit)
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      expected_content_type = Keyword.get(opts, :expected_content_type)

      # `async_nolink` against the app's TaskSupervisor, NOT a linked `Task.async`
      # (task-455ede261044ef0b). A raise inside Req or the body collector runs in
      # the task; with a link that exit is delivered to the CALLING process — the
      # Phoenix request process, which does not trap exits — and kills it outright.
      # `rescue` cannot catch a linked exit, so the caller's own error handling was
      # unreachable for the whole crash class: CycleFleet.activate_release_gate/3
      # already has `{:error, _} -> fail_release_challenge(challenge.id,
      # "capture_failed", failure)`, and that arm never ran. The challenge was left
      # with no terminal status and the operator got a bare 500. Unlinked, the
      # crash comes back as `{:exit, reason}` from `Task.yield/2` and becomes an
      # error tuple like every other failure here.
      task =
        Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
          Req.get(url,
            headers: headers,
            redirect: false,
            retry: false,
            raw: true,
            decode_body: false,
            receive_timeout: timeout,
            connect_options: [timeout: min(timeout, 5_000)],
            into: body_collector(body_limit)
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, %Req.Response{body: {:body, _size, chunks}} = response}} ->
          if expected_content_type?(response, expected_content_type) do
            body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
            {:ok, response.status, response.headers, body}
          else
            {:error, :invalid_content_type}
          end

        {:ok, {:ok, %Req.Response{body: :body_too_large}}} ->
          {:error, :response_body_too_large}

        {:ok, {:error, reason}} ->
          {:error, reason}

        nil ->
          {:error, :request_timeout}

        # A crash in the request task. Named rather than folded into the bare
        # clause below so the challenge's failure detail says what happened.
        {:exit, reason} ->
          {:error, {:http_request_crashed, reason}}

        _ ->
          {:error, :invalid_http_response}
      end
    rescue
      _ -> {:error, :http_request_failed}
    end

    defp body_collector(limit) do
      fn {:data, data}, {request, response} ->
        {size, chunks} =
          case response.body do
            {:body, size, chunks} -> {size, chunks}
            _ -> {0, []}
          end

        next_size = size + byte_size(data)

        if next_size <= limit do
          {:cont, {request, %{response | body: {:body, next_size, [data | chunks]}}}}
        else
          {:halt, {request, %{response | body: :body_too_large}}}
        end
      end
    end

    defp expected_content_type?(_response, nil), do: true

    defp expected_content_type?(response, expected) when is_binary(expected) do
      response
      |> Req.Response.get_header("content-type")
      |> Enum.any?(&(String.downcase(&1) |> String.starts_with?(String.downcase(expected))))
    end
  end

  defmodule Unavailable do
    @behaviour Barkpark.CycleFleet.ReleaseCaptureAdapter
    @impl true
    def capture(_request), do: {:error, :server_release_capture_unavailable}
  end
end
