defmodule Bonfire.Federate.ActivityPub.Import.Archive do
  @moduledoc """
  An account archive zip as an import source (see `Bonfire.Common.ImportModule`): Bonfire's own export, or Mastodon's. One name table covers both, since their file names don't collide (`likes.csv` is Bonfire's, `likes.json` Mastodon's).

  The zip is read with `Bonfire.Common.Import.Zip`, which checks every entry name before anything is read, and only the entries the import needs are ever extracted, into the staged dir. Materializing turns the picked items into import jobs: the lists for the extensions owning them, the outbox for `Bonfire.Federate.ActivityPub.Import.OutboxOps`.
  """
  @behaviour Bonfire.Common.ImportModule

  use Bonfire.Common.E
  use Bonfire.Common.Localise
  import Untangle

  alias Bonfire.Common.Import
  alias Bonfire.Common.Import.Zip
  alias Bonfire.Federate.ActivityPub.Import.OutboxOps

  # the lists, by file name: `{key, format}`, where a format says how the file holds its identifiers
  @lists %{
    "following.csv" => {:following, :csv_with_header},
    "requests.csv" => {:requests, :csv_with_header},
    "ghosted.csv" => {:ghosted, :csv_with_header},
    "silenced.csv" => {:silenced, :csv_with_header},
    "bookmarks.csv" => {:bookmarks, :csv},
    "likes.csv" => {:likes, :csv},
    "boosts.csv" => {:boosts, :csv},
    "blocked.csv" => {:blocked, :csv},
    "circles.csv" => {:circles, :csv_pairs},
    "likes.json" => {:likes, :collection},
    "bookmarks.json" => {:bookmarks, :collection}
  }

  @outbox "outbox.json"
  @actor "actor.json"

  # files an archive can hold that we don't import, keyed by their own name since nothing dispatches on them
  @not_importable ["followers.csv", "posts.csv", "messages.csv", "keys.asc"]

  @known Map.keys(@lists) ++ [@outbox, @actor] ++ @not_importable

  @impl true
  def import_source, do: :archive

  @impl true
  def import_source_label, do: l("Archive of another account (ZIP)")

  @impl true
  def stage(zip_path) when is_binary(zip_path) do
    with {:ok, entries} <- Zip.table(zip_path),
         :ok <- Zip.check_entries(entries),
         root = archive_root(Enum.map(entries, &elem(&1, 0))),
         # the names inside the archive's own folder, as the export wrote them
         names =
           for(
             {name, _size} <- entries,
             String.starts_with?(name, root),
             do: String.replace_prefix(name, root, "")
           ),
         true <-
           Enum.any?(names, &(&1 in @known)) ||
             {:error, l("This archive has nothing we know how to import")},
         {:ok, dir} <- Import.make_staging_dir(),
         zip = Path.join(dir, "archive.zip"),
         :ok <- File.cp(zip_path, zip),
         {:ok, data} <- Zip.read_entries(zip, root, Enum.filter(names, &data_file?/1)) do
      Import.enqueue_archive_cleanup(dir)

      outbox = decode(data[@outbox])

      {:ok,
       %{
         source: __MODULE__,
         dir: dir,
         zip: zip,
         root: root,
         items: items(names, data, outbox),
         summary: summary(outbox),
         media: Enum.filter(names, &media?/1),
         profile_media:
           Enum.filter(names, &profile_media?/1) ++
             actor_media_names(decode(data[@actor]), names)
       }}
    else
      {:error, _} = error -> error
      other -> error(other, l("Could not read this archive"))
    end
  end

  @doc """
  The picked items as import jobs: one per list, and the outbox's (see `OutboxOps.outbox_job/2`), lists first so a large outbox doesn't hold them up while queueing. The profile is filled in here rather than queued, from the actor document and the archive's own avatar and banner.
  """
  @impl true
  def materialize(%{zip: zip, dir: dir, items: items} = staged, keys, opts) do
    present = Map.new(items, &{&1.key, &1})
    root = Map.get(staged, :root, "")

    list_files =
      for {name, {key, format}} <- @lists,
          key in keys,
          present[key],
          into: %{},
          do: {name, {key, format}}

    with {:ok, data} <-
           Zip.read_entries(
             zip,
             root,
             Map.keys(list_files) ++
               if(:posts in keys, do: [@outbox], else: []) ++
               if(:posts in keys or :profile in keys, do: [@actor], else: [])
           ),
         {:ok, media_dir} <-
           Zip.extract(zip, dir, root, if(:posts in keys, do: staged.media, else: [])),
         {:ok, profile_dir} <-
           Zip.extract(zip, dir, root, if(:profile in keys, do: staged.profile_media, else: [])) do
      actor = decode(data[@actor])

      list_jobs =
        list_files
        |> Enum.reduce(%{}, fn {name, {key, format}}, acc ->
          identifiers = parse(format, data[name])
          Map.update(acc, key, identifiers, &(&1 ++ identifiers))
        end)
        |> Enum.map(fn {key, identifiers} ->
          %{key: key, op: Import.list_op(key), identifiers: identifiers}
        end)

      outbox_data = if :posts in keys, do: decode(data[@outbox])

      outbox =
        if is_map(outbox_data),
          do:
            OutboxOps.outbox_job(outbox_data,
              actor: actor,
              media_dir: media_dir,
              include_boosts: opts[:include_boosts] == true
            )

      done =
        if :profile in keys and is_map(actor),
          do: %{profile: OutboxOps.import_profile(opts[:current_user], actor, profile_dir)},
          else: %{}

      {:ok,
       %{
         jobs: list_jobs ++ List.wrap(outbox && outbox.job),
         done: done,
         notes: List.wrap(outbox && outbox.notes),
         skipped: List.wrap(outbox && outbox.skipped)
       }}
    end
  end

  # The folder in the zip that holds the archive's own files: none, as an export writes it, or the folders around them when someone unzipped the archive and zipped the folder again. Found by the shallowest `outbox.json` or `actor.json`
  defp archive_root(names) do
    if Enum.any?(names, &(&1 in @known)) do
      ""
    else
      names
      |> Enum.filter(&(Path.basename(&1) in [@outbox, @actor]))
      |> Enum.min_by(&length(Path.split(&1)), fn -> nil end)
      |> case do
        nil -> ""
        name -> Path.dirname(name) <> "/"
      end
    end
  end

  # what importing the archive will do that its checklist doesn't show: its posts addressed to nobody, which come in visible only to the importer
  defp summary(outbox) do
    case OutboxOps.count_addressed_to_nobody(outbox) do
      0 ->
        []

      count ->
        [
          %{
            key: l("Content"),
            reason:
              lp(
                "%{count} post will be visible only to you",
                "%{count} posts will be visible only to you",
                count,
                count: count
              )
          }
        ]
    end
  end

  defp items(names, data, outbox) do
    lists =
      for {name, {key, format}} <- @lists, name in names do
        count = length(parse(format, data[name]))

        # an empty file is shown greyed with why, rather than as a box that would import nothing
        %{
          key: key,
          label: list_label(key),
          count: count,
          importable?: count > 0,
          reason: if(count == 0, do: l("Nothing to import in it"))
        }
      end
      # a key from two files (only possible with a mixed archive) is offered once
      |> Enum.uniq_by(& &1.key)

    posts =
      if @outbox in names do
        media = Enum.count(names, &media?/1)
        count = outbox |> outbox_items() |> length()

        [
          %{
            key: :posts,
            # everything in the outbox, posts and boosts alike, hence "objects"
            label: l("Content"),
            detail:
              Enum.join(
                [lp("%{count} object", "%{count} objects", count, count: count)] ++
                  if(media > 0,
                    do: [
                      lp("with %{count} media file", "with %{count} media files", media,
                        count: media
                      )
                    ],
                    else: []
                  ),
                ", "
              ),
            count: count,
            importable?: true,
            reason: nil,
            # an outbox holds boosts too, brought in only when asked for, since an archive from Mastodon has no separate list of them
            options: [%{key: :include_boosts, label: l("Also import boosts"), default: false}]
          }
        ]
      else
        []
      end

    profile =
      if @actor in names,
        # no count: there is one profile, and "Profile (1)" says nothing
        do: [
          %{
            key: :profile,
            label:
              l("Profile: bio, location, avatar and banner (only if they are currently empty)"),
            count: nil,
            importable?: true,
            reason: nil
          }
        ],
        else: []

    skipped =
      for name <- @not_importable, name in names do
        %{
          key: name,
          label: name,
          count: nil,
          importable?: false,
          reason: not_importable_reason(name)
        }
      end

    posts ++ lists ++ profile ++ skipped
  end

  # Bonfire's export ends its list with an empty item, which isn't a post
  defp outbox_items(%{"orderedItems" => items}) when is_list(items),
    do: Enum.filter(items, &(is_map(&1) and map_size(&1) > 0))

  defp outbox_items(_), do: []

  defp parse(_format, nil), do: []

  # an export with nothing in that list has only its header row, which the one-line fallback of `parse_list/2` (for an uploaded plain text file) would read as a handle
  defp parse(:csv_with_header, csv) do
    if csv |> String.trim() |> String.contains?("\n"),
      do: Import.parse_list(csv, true),
      else: []
  end

  defp parse(:csv, csv), do: Import.parse_list(csv, false)
  defp parse(:csv_pairs, csv), do: Import.parse_pairs(csv, false)

  defp parse(:collection, json) do
    case decode(json) do
      %{"orderedItems" => items} when is_list(items) ->
        for item <- items,
            id = (is_binary(item) && item) || e(item, "id", nil),
            is_binary(id),
            do: id

      _ ->
        []
    end
  end

  defp decode(nil), do: nil

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, data} -> data
      _ -> nil
    end
  end

  defp data_file?(name), do: name in @known and name not in ["keys.asc"]

  defp profile_media?(name), do: Path.rootname(name) in ["avatar", "header"]

  # Bonfire's archive keeps the avatar and banner among its uploads, named by the URL `actor.json` gives them: at `host/path`, or at `path`
  defp actor_media_names(%{} = actor, names) do
    for field <- ["icon", "image"],
        url = e(actor, field, "url", nil),
        is_binary(url),
        uri = URI.parse(url),
        path = String.trim_leading(uri.path || "", "/"),
        name <- Enum.reject([uri.host && Path.join(uri.host, path), path], &is_nil/1),
        name in names,
        uniq: true,
        do: name
  end

  defp actor_media_names(_actor, _names), do: []

  defp media?(name), do: name not in @known and not profile_media?(name)

  defp list_label(:following), do: l("Profiles you follow")
  defp list_label(:requests), do: l("Follow requests you sent")
  defp list_label(:ghosted), do: l("Ghosted profiles")
  defp list_label(:silenced), do: l("Silenced profiles")
  defp list_label(:blocked), do: l("Blocked profiles")
  defp list_label(:bookmarks), do: l("Bookmarks")
  defp list_label(:likes), do: l("Likes")
  defp list_label(:boosts), do: l("Boosts")
  defp list_label(:circles), do: l("Circles and their members")

  defp not_importable_reason("followers.csv"),
    do: l("Followers have to follow you again from their own account")

  defp not_importable_reason("posts.csv"), do: l("Posts are imported from the outbox")
  defp not_importable_reason("messages.csv"), do: l("Messages can't be imported")

  defp not_importable_reason("keys.asc"),
    do: l("Your keys belong to the old account, moving it uses them there")
end
