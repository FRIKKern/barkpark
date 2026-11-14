defmodule Barkpark.StudioChat.AttachmentsFileTypesTest do
  @moduledoc """
  The chat store's two file types (`/papers/chat-host-file-attachments-plan`,
  T1). `Attachments.put/2` sniffs `text/plain` (valid UTF-8 with no NUL byte)
  and `application/pdf` (bytes that start with `%PDF-`) besides the four
  images, and refuses everything else. The refused set is an allowlist's
  complement, so the named binaries below are pinned by case, not by a rule
  that happens to cover them today.
  """
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments

  setup do
    prev = Application.get_env(:barkpark, StudioChat)

    dir =
      Path.join(
        System.tmp_dir!(),
        "bp_chat_file_types_test_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:barkpark, StudioChat, prev),
        else: Application.delete_env(:barkpark, StudioChat)
    end)

    %{dir: dir, sid: Ecto.UUID.generate()}
  end

  # A CSV with a multi-byte character, so "valid UTF-8" is not only ASCII.
  @csv "name,city\nÅse,Tromsø\nBjørn,Bodø\n"

  # A real PDF opening: the header, then the binary marker comment every
  # writer emits (bytes over 0x7F, which are not valid UTF-8 on their own).
  @pdf "%PDF-1.7\n%" <> <<0xE2, 0xE3, 0xCF, 0xD3>> <> "\n1 0 obj\n<<>>\nendobj\n%%EOF\n"

  test "a UTF-8 text file is stored as text/plain and a PDF as application/pdf, and the pointer keeps that type",
       %{sid: sid} do
    for {bytes, type} <- [{@csv, "text/plain"}, {@pdf, "application/pdf"}] do
      result = Attachments.put(sid, bytes)
      assert match?({:ok, _}, result), "#{type} must be stored; got #{inspect(result)}"
      {:ok, pointer} = result
      assert pointer.media_type == type

      json = Attachments.pointer_json(pointer)
      assert json["media_type"] == type, "the row pointer must keep #{type}, not image/png"

      ref = Attachments.reference(json, sid)
      assert ref.media_type == type, "the wire reference must keep #{type}"
      assert ref.byte_size == byte_size(bytes)

      assert {:ok, fetched} = Attachments.fetch(sid, ref.id)
      assert fetched.media_type == type
      assert fetched.bytes == bytes
    end

    assert Attachments.file_types() == ["text/plain", "application/pdf"]

    assert Attachments.media_types() == ~w(image/png image/jpeg image/gif image/webp),
           "media_types/0 stays the four images, so its three readers do not widen"
  end

  test "zip, docx, exe, ELF, Mach-O, gzip, UTF-16 and invalid UTF-8 bytes are refused as unsupported_media_type",
       %{sid: sid, dir: dir} do
    {:ok, {_, zip}} = :zip.create(~c"notes.zip", [{~c"notes.txt", "hello"}], [:memory])

    {:ok, {_, docx}} =
      :zip.create(
        ~c"report.docx",
        [{~c"[Content_Types].xml", "<Types/>"}, {~c"word/document.xml", "<w:document/>"}],
        [:memory]
      )

    # A DOS/PE header: "MZ", the stub fields, then e_lfanew and the PE
    # signature, which holds NUL bytes by definition ("PE\0\0").
    exe =
      "MZ" <>
        <<0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF>> <>
        :binary.copy(<<0>>, 48) <> "PE" <> <<0, 0>>

    elf = <<0x7F, "ELF", 2, 1, 1, 0>> <> :binary.copy(<<0>>, 8) <> <<2, 0, 0xB7, 0>>
    macho = <<0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01>>
    fat_macho = <<0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02>>
    gzip = :zlib.gzip("hello hello hello")
    utf16le = <<0xFF, 0xFE>> <> :unicode.characters_to_binary("hello", :utf8, {:utf16, :little})
    utf16be = <<0xFE, 0xFF>> <> :unicode.characters_to_binary("hello", :utf8, {:utf16, :big})
    # UTF-16 without a byte order mark: ASCII letters carry a NUL each.
    utf16_bare = :unicode.characters_to_binary("hello", :utf8, {:utf16, :little})
    invalid_utf8 = <<"abc", 0xC3, 0x28, "def">>
    text_with_nul = "abc" <> <<0>> <> "def"
    # A PDF with bytes in front of the header is not sniffed as a PDF, and its
    # binary marker line keeps it from passing as text.
    late_pdf = "junk" <> @pdf

    cases = [
      {"zip", zip},
      {"docx", docx},
      {"exe", exe},
      {"ELF", elf},
      {"Mach-O", macho},
      {"fat Mach-O", fat_macho},
      {"gzip", gzip},
      {"UTF-16LE with BOM", utf16le},
      {"UTF-16BE with BOM", utf16be},
      {"UTF-16 without BOM", utf16_bare},
      {"invalid UTF-8", invalid_utf8},
      {"text with a NUL byte", text_with_nul},
      {"PDF with leading bytes", late_pdf}
    ]

    for {label, bytes} <- cases do
      assert Attachments.put(sid, bytes) == {:error, :unsupported_media_type},
             "#{label} must be refused as unsupported_media_type"
    end

    refute File.dir?(Path.join(dir, sid)), "a refused upload must write nothing"
  end

  test "put_image/2 still refuses a text file or a PDF, so the Studio composer stays images only",
       %{sid: sid} do
    assert Attachments.put_image(sid, @csv) == {:error, :unsupported_media_type}
    assert Attachments.put_image(sid, @pdf) == {:error, :unsupported_media_type}

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      )

    assert {:ok, %{media_type: "image/png"}} = Attachments.put_image(sid, png)
  end
end
