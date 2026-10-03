defmodule Mix.Tasks.Barkpark.PortableDoc.GenGoldenEmail do
  @moduledoc """
  Regenerate the `:email` render byte-lock golden,
  `api/test/barkpark/portable_doc/render/email_golden.html`.

      mix barkpark.portable_doc.gen_golden_email
      mix barkpark.portable_doc.gen_golden_email --out /tmp/email_golden.html

  The golden is `Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:email))`,
  written verbatim with no trailing newline. `email_golden_test.exs` asserts raw
  byte identity against it, so on an unchanged tree this task rewrites the same
  bytes and `git diff` stays empty.

  Email output should almost never move. Regenerate only when an `:email`
  change is intended, in the same diff as that change, and say why in review.

  The fixture lives in `test/support/portable_doc_parity_fixture.ex`, which is
  compiled only under `MIX_ENV=test`. In any other env this task loads it from
  that file.
  """
  use Mix.Task

  alias Barkpark.PortableDoc.Render

  @shortdoc "Regenerate the :email render byte-lock golden (email_golden.html)"

  @golden_path Path.expand(
                 "../../../test/barkpark/portable_doc/render/email_golden.html",
                 __DIR__
               )
  @fixture_path Path.expand("../../../test/support/portable_doc_parity_fixture.ex", __DIR__)
  @fixture Barkpark.PortableDoc.Render.ParityFixture

  @doc "The committed golden's path."
  def golden_path, do: @golden_path

  @doc "The golden's bytes, rendered from the shared parity fixture."
  def render do
    # The module is test-only, so it is called through a variable: a literal
    # remote call fails `mix compile --warnings-as-errors` in prod, where the
    # module does not exist at compile time.
    fixture = @fixture
    unless Code.ensure_loaded?(fixture), do: Code.require_file(@fixture_path)
    Render.render_html(apply(fixture, :tree, []), apply(fixture, :render_opts, [:email]))
  end

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [out: :string])
    path = Keyword.get(opts, :out, @golden_path)

    html = render()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, html)
    Mix.shell().info("wrote #{path} (#{byte_size(html)} bytes)")
  end
end
