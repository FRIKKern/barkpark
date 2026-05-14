defmodule Mix.Tasks.Onix.ExportProof do
  @moduledoc """
  Regenerate the Phase 6 WI8 ONIX 3.0 proof artifact at `proof/onix-sample.xml`.

  This task is the canonical regeneration tool for the committed proof
  artifact that demonstrates the OnixEdit export pipeline produces
  EDItEUR-conformant ONIX 3.0 XML end-to-end.

  Pipeline:

    1. Read the source fixture (default: `test/fixtures/onix/full-book.json`)
       — exercises multi-Thema MainSubject nesting, multi-contributor,
       nb-NO + eng descriptions (ISO 639-2/B "nob"), multi-supplier
       productSupplies, ProductFormDetail, and a cover-image
       SupportingResource.
    2. Decode it with `Jason`.
    3. Pipe through `Barkpark.Plugins.OnixEdit.Export.to_string/1`, which
       runs the xmllint XSD gate against
       `priv/onix/onix-3.0/ONIX_BookProduct_3.0_reference.xsd` before
       returning. Validation failure raises and never touches the
       filesystem.
    4. Write the validated XML binary to the output path
       (default: `../proof/onix-sample.xml`, i.e. `<repo>/proof/onix-sample.xml`).

  ## Usage

      cd api && mix onix.export_proof
      cd api && mix onix.export_proof --output ../proof/onix-sample.xml
      cd api && mix onix.export_proof --fixture test/fixtures/onix/full-book.json

  Drift between the live exporter and the committed artifact is enforced
  by `test/barkpark/plugins/onixedit/export_proof_test.exs`. When that
  test fails, re-run this task and commit the updated XML.
  """
  @shortdoc "Regenerate proof/onix-sample.xml from full-book.json"

  use Mix.Task

  @switches [output: :string, fixture: :string]

  @default_fixture "test/fixtures/onix/full-book.json"
  @default_output "../proof/onix-sample.xml"

  # Pinned to keep the regenerated proof artifact byte-stable across runs.
  # The exporter stamps `<SentDateTime>` with `DateTime.utc_now/0` by default;
  # passing an explicit timestamp here means repeated `mix onix.export_proof`
  # invocations produce identical bytes.
  @pinned_sent_at ~U[2026-04-29 12:00:00Z]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown switches: #{inspect(invalid)}")
    end

    fixture_path = Path.expand(Keyword.get(opts, :fixture, @default_fixture), File.cwd!())
    output_path = Path.expand(Keyword.get(opts, :output, @default_output), File.cwd!())

    Mix.Task.run("app.start")

    Mix.shell().info("==> reading fixture: #{fixture_path}")

    book =
      case File.read(fixture_path) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            {:error, reason} -> Mix.raise("invalid JSON in fixture: #{inspect(reason)}")
          end

        {:error, reason} ->
          Mix.raise("could not read fixture #{fixture_path}: #{inspect(reason)}")
      end

    Mix.shell().info("==> exporting via Barkpark.Plugins.OnixEdit.Export.to_string/1")

    case Barkpark.Plugins.OnixEdit.Export.to_string(book, sent_at: @pinned_sent_at) do
      {:ok, xml} ->
        File.mkdir_p!(Path.dirname(output_path))
        File.write!(output_path, xml)
        Mix.shell().info("==> wrote #{byte_size(xml)} bytes to #{output_path}")
        :ok

      {:error, {:xsd_invalid, reasons}} ->
        Mix.raise("XSD validation failed:\n  - " <> Enum.join(reasons, "\n  - "))
    end
  end
end
