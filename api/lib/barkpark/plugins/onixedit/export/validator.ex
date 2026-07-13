defmodule Barkpark.Plugins.OnixEdit.Export.Validator do
  @moduledoc """
  ONIX 3.0 XSD validation gate via xmllint.

  Formal gate that blocks invalid ONIX XML from shipping. Runs
  `xmllint --noout --schema` against the EDItEUR Reference XSD vendored under
  `api/priv/onix/onix-3.0/` (Issue 73 / Revision 8 / schema version 3.0.8.0,
  see WI1 for provenance).

  ## Local development

  Tests using this validator are tagged `@moduletag :validator`. If `xmllint`
  is not on `PATH`, the test module skips cleanly via `setup_all` and the
  validator itself returns
  `{:error, ["xmllint not on PATH; install libxml2-utils to run validator"]}`.

  Install locally:

    * Debian/Ubuntu: `sudo apt-get install -y libxml2-utils`
    * macOS:        `brew install libxml2` (xmllint ships with the Homebrew formula)

  ## CI

  CI installs `libxml2-utils` before `mix test`, so `:validator` tests run by
  default. There is no `--exclude :validator` on CI — the gate must run.
  """

  @xsd_filename "ONIX_BookProduct_3.0_reference.xsd"

  # Resource bounds on the content-editor-controlled ONIX payload: a hard byte cap
  # (checked BEFORE any tmp write, so a pathological document can't pin disk/RAM)
  # and a hard deadline on the xmllint shell-out (so a wedged validate can't hang
  # the export/Bokbasen worker). Both config-overridable per env for tests via
  # `config :barkpark, __MODULE__, max_bytes: N, timeout_ms: N`; a `bin:` override
  # injects a stub xmllint so the deadline is testable with no libxml2 install.
  @default_max_bytes 25 * 1024 * 1024
  @default_timeout_ms 30_000

  @doc """
  Returns the absolute path to the vendored ONIX 3.0 reference XSD, resolved
  via `Application.app_dir(:barkpark, "priv/onix/onix-3.0/...")` so it works
  regardless of the calling process's working directory.
  """
  @spec default_xsd_path() :: Path.t()
  def default_xsd_path do
    Application.app_dir(:barkpark, Path.join(["priv", "onix", "onix-3.0", @xsd_filename]))
  end

  @doc """
  Validate an iodata XML payload against an ONIX 3.0 XSD.

  Returns `:ok` on success, `{:error, [reason, ...]}` on failure. Reasons are
  the human-readable lines extracted from xmllint's stderr; if no recognisable
  diagnostic lines are present, the full trimmed output is returned as a
  single reason. xmllint missing on `PATH` returns a single explanatory error.
  """
  @spec validate_xsd(iodata(), Path.t()) :: :ok | {:error, [String.t()]}
  def validate_xsd(xml_iodata, xsd_path \\ default_xsd_path()) do
    case xmllint_bin() do
      nil ->
        {:error, ["xmllint not on PATH; install libxml2-utils to run validator"]}

      xmllint ->
        run_xmllint(xmllint, xml_iodata, xsd_path)
    end
  end

  defp xmllint_bin, do: Keyword.get(config(), :bin) || System.find_executable("xmllint")

  defp config, do: Application.get_env(:barkpark, __MODULE__, [])

  defp max_bytes, do: Keyword.get(config(), :max_bytes, @default_max_bytes)

  defp timeout_ms, do: Keyword.get(config(), :timeout_ms, @default_timeout_ms)

  # Sobelow Traversal.FileModule is a false-positive: the tmp path is server-built
  # under `System.tmp_dir!` with a unique-integer name (never request data). This
  # inline skip replaces the line-anchored `.sobelow-skips` fingerprints
  # (`validator.ex:68` File.write!, `:79` File.rm) that the size-cap refactor moved
  # these calls off of.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_xmllint(xmllint, xml_iodata, xsd_path) do
    binary = IO.iodata_to_binary(xml_iodata)
    cap = max_bytes()

    if byte_size(binary) > cap do
      # Size cap fires BEFORE any tmp write or shell-out — a pathological/oversized
      # ONIX payload is refused cheaply, never given a chance to pin disk+RAM.
      {:error,
       ["ONIX XML payload is #{byte_size(binary)} bytes, over the #{cap}-byte validation cap"]}
    else
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "barkpark-onix-#{System.unique_integer([:positive])}.xml"
        )

      File.write!(tmp_path, binary)

      try do
        case bounded_xmllint(xmllint, xsd_path, tmp_path) do
          {:timeout, ms} ->
            {:error, ["xmllint validation exceeded #{ms}ms deadline"]}

          {:crashed, reason} ->
            {:error, ["xmllint validation crashed: #{inspect(reason)}"]}

          {_output, 0} ->
            :ok

          {output, _code} ->
            {:error, parse_reasons(output)}
        end
      after
        _ = File.rm(tmp_path)
      end
    end
  end

  # Run xmllint under a hard deadline (mirrors the per-site Task.yield+brutal_kill
  # pattern; async_nolink so a crash degrades to a tuple, not a caller exit).
  #
  # Sobelow CI.System is a false-positive: xmllint is a fixed binary and the argv
  # is a fixed token list + a server-generated tmp path — no shell string, no
  # client input. This inline skip replaces the line-anchored `.sobelow-skips`
  # fingerprint (`validator.ex:72`) that the deadline wrapper moved System.cmd off.
  # sobelow_skip ["CI.System"]
  defp bounded_xmllint(xmllint, xsd_path, tmp_path) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        System.cmd(xmllint, ["--noout", "--schema", xsd_path, tmp_path], stderr_to_stdout: true)
      end)

    ms = timeout_ms()

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:crashed, reason}
      nil -> {:timeout, ms}
    end
  end

  defp parse_reasons(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(fn line ->
      Regex.match?(~r/element|complexType|attribute|fails to validate/i, line)
    end)
    |> case do
      [] -> [String.trim(output)]
      lines -> lines
    end
  end
end
