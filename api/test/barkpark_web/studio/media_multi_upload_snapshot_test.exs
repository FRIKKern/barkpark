defmodule BarkparkWeb.Studio.MediaMultiUploadSnapshotTest do
  @moduledoc """
  Choosing several files in the media explorer must upload every one of them.

  The `change` handler passed the input's LIVE `FileList` to the async
  `_uploadFiles/1` and then cleared `e.target.value` in the same tick, so the
  list emptied under the loop: the first file uploaded before the first
  `await`, every later iteration found nothing. Found in a real browser
  (run-4 lane C dogfood): six files chosen, one asset created, no error shown.

  Source pin, the same shape as the explorer's other pins
  (`media_failed_badge_variant_test.exs`): the explorer is a plain custom
  element in `priv/static/assets`, with no JS harness in the api gate.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-asset-explorer.js", __DIR__)

  test "the upload handler snapshots the FileList before clearing the input" do
    js = File.read!(@js)

    [handler] =
      Regex.run(
        ~r/this\._uploadInput\.addEventListener\("change", \(e\) => \{(.*?)\n      \}\);/s,
        js,
        capture: :all_but_first
      )

    assert handler =~ ~r/const files = Array\.from\(e\.target\.files/,
           "the change handler must copy the live FileList (Array.from) before the input is cleared"

    refute handler =~ ~r/const files = e\.target\.files\b/,
           "the change handler still hands the LIVE FileList to the async uploader"

    assert handler =~ ~s(e.target.value = ""),
           "premise moved: the handler no longer clears the input"
  end
end
