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
    case System.find_executable("xmllint") do
      nil ->
        {:error, ["xmllint not on PATH; install libxml2-utils to run validator"]}

      xmllint ->
        run_xmllint(xmllint, xml_iodata, xsd_path)
    end
  end

  defp run_xmllint(xmllint, xml_iodata, xsd_path) do
    binary = IO.iodata_to_binary(xml_iodata)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "barkpark-onix-#{System.unique_integer([:positive])}.xml"
      )

    File.write!(tmp_path, binary)

    try do
      {output, exit_code} =
        System.cmd(xmllint, ["--noout", "--schema", xsd_path, tmp_path], stderr_to_stdout: true)

      case exit_code do
        0 -> :ok
        _ -> {:error, parse_reasons(output)}
      end
    after
      _ = File.rm(tmp_path)
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
