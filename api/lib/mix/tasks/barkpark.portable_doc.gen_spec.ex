defmodule Mix.Tasks.Barkpark.PortableDoc.GenSpec do
  @moduledoc """
  Write the PortableDoc block spec, `api/priv/portable_doc/spec/blocks.schema.json`.

      mix barkpark.portable_doc.gen_spec
      mix barkpark.portable_doc.gen_spec --out /tmp/blocks.schema.json

  The file is `Barkpark.PortableDoc.Spec.json/0`: a JSON Schema of every block
  type the reader renders, with sorted keys and no timestamps, so an unchanged
  tree rewrites the same bytes. `spec_test.exs` fails when the committed file is
  stale, so regenerate in the same diff as any change to a block type, its
  fields, its tier or the constraint vocabulary.

  The file syncs to the public portable-doc repo as `spec/blocks.schema.json`.
  """
  use Mix.Task

  alias Barkpark.PortableDoc.Spec

  @shortdoc "Write the PortableDoc block spec (blocks.schema.json)"
  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [out: :string])
    path = Keyword.get(opts, :out, Spec.path())

    json = Spec.json()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)
    Mix.shell().info("wrote #{path} (#{byte_size(json)} bytes)")
  end
end
