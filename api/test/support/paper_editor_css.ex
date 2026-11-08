defmodule Barkpark.Test.PaperEditorCSS do
  @moduledoc false

  @source_root Path.expand("../../assets/paper-editor/src", __DIR__)
  @entry Path.join(@source_root, "styles.css")
  @authored_root Path.join(@source_root, "styles")
  @shared Path.join(@source_root, "code-tokens.css")
  @import ~r/@import\s+["']([^"']+)["']\s*;/

  def authored_css! do
    entry = realpath!(@entry)
    authored_root = realpath!(@authored_root)
    shared = realpath!(@shared)
    {parts, seen} = visit(entry, entry, authored_root, shared, MapSet.new(), [])

    if MapSet.size(seen) < 2 do
      raise "paper-editor CSS graph contains no authored fragments"
    end

    imported = MapSet.delete(seen, entry)
    on_disk = authored_files!(authored_root)

    case MapSet.difference(on_disk, imported) |> MapSet.to_list() do
      [] -> :ok
      [orphan | _] -> raise "orphan paper-editor CSS is not reachable from styles.css: #{orphan}"
    end

    if MapSet.size(on_disk) != MapSet.size(imported) do
      raise "paper-editor CSS authored-file census disagrees with the import graph"
    end

    IO.iodata_to_binary(parts)
  end

  defp visit(path, entry, authored_root, shared, seen, stack) do
    canonical = realpath!(path)

    if canonical in stack do
      raise "paper-editor CSS import cycle: #{Enum.join(Enum.reverse([canonical | stack]), " -> ")}"
    end

    if MapSet.member?(seen, canonical) do
      raise "paper-editor CSS imports the same canonical file twice: #{canonical}"
    end

    unless canonical == entry or inside?(canonical, authored_root) do
      raise "paper-editor CSS import escapes the authored directory: #{canonical}"
    end

    source = File.read!(canonical)
    imports = Regex.scan(@import, source, capture: :all_but_first) |> List.flatten()
    without_imports = Regex.replace(@import, source, "")

    if Regex.match?(~r/@import\b/, without_imports) do
      raise "paper-editor CSS contains an unsupported import form: #{canonical}"
    end

    first_rule = first_rule_offset(source)

    Enum.each(Regex.scan(@import, source, return: :index), fn [{offset, _} | _] ->
      if first_rule && offset > first_rule do
        raise "paper-editor CSS contains a late import: #{canonical}"
      end
    end)

    if canonical == entry do
      if String.trim(without_imports |> strip_comments()) != "" do
        raise "paper-editor styles.css must contain imports and comments only"
      end

      case imports do
        [shared_spec | authored] when authored != [] ->
          if resolve_import!(canonical, shared_spec) != shared do
            raise "paper-editor styles.css must import canonical code-tokens.css first"
          end

        _ ->
          raise "paper-editor styles.css must import shared tokens followed by authored CSS"
      end
    end

    next_seen = MapSet.put(seen, canonical)

    imports
    |> Enum.with_index()
    |> Enum.reduce({[], next_seen}, fn {specifier, index}, {parts, acc_seen} ->
      child = resolve_import!(canonical, specifier)

      cond do
        canonical == entry and index == 0 and child == shared ->
          {parts, acc_seen}

        child == shared ->
          raise "shared code tokens may only be the first root import"

        true ->
          {child_parts, child_seen} =
            visit(child, entry, authored_root, shared, acc_seen, [canonical | stack])

          {parts ++ child_parts, child_seen}
      end
    end)
    |> then(fn {parts, final_seen} ->
      own = if canonical == entry, do: "", else: Regex.replace(@import, source, "")
      {[parts, own], final_seen}
    end)
  end

  defp resolve_import!(from, specifier) do
    if String.contains?(specifier, ["?", "#", "\\"]) or
         String.starts_with?(specifier, ["/", "http:", "https:", "data:"]) do
      raise "paper-editor CSS contains a non-local import: #{specifier}"
    end

    from |> Path.dirname() |> Path.join(specifier) |> realpath!()
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp strip_comments(source), do: Regex.replace(~r{/\*[\s\S]*?\*/}, source, "")

  defp authored_files!(directory) do
    directory
    |> File.ls!()
    |> Enum.reduce(MapSet.new(), fn name, files ->
      path = Path.join(directory, name)

      cond do
        File.dir?(path) -> MapSet.union(files, authored_files!(path))
        String.ends_with?(name, ".css") -> MapSet.put(files, realpath!(path))
        true -> files
      end
    end)
  end

  defp first_rule_offset(source) do
    comments_removed =
      Regex.replace(~r{/\*[\s\S]*?\*/}, source, fn match ->
        String.duplicate(" ", byte_size(match))
      end)

    Regex.replace(@import, comments_removed, fn match ->
      String.duplicate(" ", byte_size(match))
    end)
    |> :binary.match("{")
    |> case do
      {offset, _} -> offset
      :nomatch -> nil
    end
  end

  defp realpath!(path), do: resolve_components(Path.split(Path.expand(path)), nil, MapSet.new())

  defp resolve_components([], resolved, _seen), do: resolved

  defp resolve_components([part | rest], nil, seen),
    do: resolve_components(rest, part, seen)

  defp resolve_components([part | rest], resolved, seen) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        if MapSet.member?(seen, candidate), do: raise("symlink cycle in CSS path: #{candidate}")

        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(candidate))

        target_parts = Path.split(target)
        resolved_target = resolve_components(target_parts, nil, MapSet.put(seen, candidate))
        resolve_components(rest, resolved_target, MapSet.put(seen, candidate))

      {:error, :einval} ->
        unless File.exists?(candidate), do: raise("missing CSS source: #{candidate}")
        resolve_components(rest, candidate, seen)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "resolve CSS source", path: candidate
    end
  end
end
