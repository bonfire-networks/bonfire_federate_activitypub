defmodule Bonfire.Federate.ActivityPub.Import.OutboxOps do
  @moduledoc """
  The import ops for an ActivityPub outbox (posts, and boosts when asked for) and profile, from an account archive or an outbox JSON file, in the op role of `Bonfire.Common.ImportModule`: `Bonfire.Common.Import`'s worker hands each job to `perform_import/3`. The likes and boosts themselves are done by `Bonfire.Social.ImportOps`.
  """
  @behaviour Bonfire.Common.ImportModule

  use Arrows

  import Untangle
  use Bonfire.Common.E
  use Bonfire.Common.Localise
  use Bonfire.Common.Settings
  use Bonfire.Common.Config
  use Bonfire.Common.Repo
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Enums
  alias Bonfire.Me.Users
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.ImportOps

  @impl Bonfire.Common.ImportModule
  def import_ops, do: ["outbox_creations_import", "outbox_import"]

  @impl Bonfire.Common.ImportModule
  def import_op_label("outbox_import"), do: l("Posts & boosts")
  def import_op_label("outbox_creations_import"), do: l("Posts/Creations")
  def import_op_label(_), do: nil

  @impl Bonfire.Common.ImportModule
  def import_op_phrase("outbox_import"), do: l("Importing object or boost")
  def import_op_phrase("outbox_creations_import"), do: l("Importing object")
  def import_op_phrase(_), do: nil

  @doc """
  Import user's outbox (posts and activities) from a JSON file.

  ## Examples

      iex> import_from_json_file(:outbox, user, "path/to/outbox.json")
      %{ok: 5, error: 1, notes: [], skipped: []}

  """
  def import_from_json_file(type, user, path, opts \\ []) do
    with {:ok, json_content} <- File.read(path),
         {:ok, outbox_data} <- Jason.decode(json_content) do
      import_from_json(type, user, outbox_data, opts)
    else
      error ->
        error(error, "Failed to read or parse JSON file")
    end
  end

  @doc """
  Import user's outbox from parsed JSON data: queues one job per activity (see `outbox_job/2`), and returns how many were queued, plus the report's notes and what was left out.
  """
  def import_from_json(type, user_id, outbox_data, opts \\ [])

  def import_from_json(:outbox = _type, user, outbox_data, opts) do
    %{job: job, notes: notes, skipped: skipped} = outbox_job(outbox_data, opts)

    Bonfire.Common.Import.enqueue_many(
      job.op,
      Enums.id(user),
      job.identifiers,
      job.args,
      priority: job.priority
    )
    |> Map.put(:notes, notes)
    |> Map.put(:skipped, skipped)
  end

  @doc """
  The import job for an outbox's activities (an `ImportModule` job, see `Bonfire.Common.ImportModule.materialize/3`), with the report's notes (posts that come in visible only to the importer) and what's left out (the boosts, unless `include_boosts: true`).

  Before that, the old account's actor (`actor:`, from an archive) is created when its server no longer answers, so each post finds its author already known rather than each falling back to the service actor.
  """
  def outbox_job(outbox_data, opts \\ []) do
    # the outbox's boosts are only queued when asked for, so what's reported as queued is what gets imported
    {boosts, activities} =
      outbox_data
      |> Map.get("orderedItems", [])
      |> Enum.split_with(&(!opts[:include_boosts] and e(&1, "type", nil) == "Announce"))

    # a post addressed to nobody (Mastodon's private mention with no one mentioned, a note to self) comes in visible only to the person importing it, which the report says
    to_nobody = Enum.filter(activities, &addressed_to_nobody?/1)

    maybe_create_gone_author(opts[:actor], activities)

    %{
      # TODO: should we only save the type and object id in the queue metadata?
      job: %{
        key: :posts,
        op: if(opts[:include_boosts], do: "outbox_import", else: "outbox_creations_import"),
        identifiers: activities,
        args: if(opts[:media_dir], do: %{"media_dir" => opts[:media_dir]}, else: %{}),
        # the posts first, so someone moving here sees their own posts before their likes, bookmarks and other lists come in. Oban runs a lower number first, and runs several jobs at once, so the posts start first rather than all finishing first
        priority: 0
      },
      notes:
        for(
          activity <- to_nobody,
          do: %{
            key: e(activity, "object", "id", nil) || e(activity, "id", nil),
            reason: l("Imported, visible only to you")
          }
        ),
      skipped:
        if(boosts != [],
          do: [
            %{
              key: l("Boosts"),
              reason:
                lp(
                  "%{count} boost left out, since importing boosts wasn't ticked",
                  "%{count} boosts left out, since importing boosts wasn't ticked",
                  length(boosts),
                  count: length(boosts)
                )
            }
          ],
          else: []
        )
    }
  end

  @doc "How many of an outbox's posts are addressed to nobody, so they'd come in visible only to the importer: for saying so before importing. Has no side effects."
  def count_addressed_to_nobody(%{} = outbox_data),
    do:
      outbox_data
      |> Map.get("orderedItems", [])
      |> List.wrap()
      |> Enum.count(&addressed_to_nobody?/1)

  def count_addressed_to_nobody(_), do: 0

  # only a post that says so: Mastodon writes `"to": []` and `"cc": []`, while a post with no addressing at all is malformed, and fails like any other
  defp addressed_to_nobody?(%{"type" => "Create", "object" => %{} = object} = activity) do
    (Map.has_key?(activity, "to") or Map.has_key?(object, "to")) and
      [activity["to"], activity["cc"], object["to"], object["cc"], object["bto"], object["bcc"]]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.empty?()
  end

  defp addressed_to_nobody?(_), do: false

  # The old account's actor document from an archive (`actor.json`), for when its server no longer answers, eg. the account was deleted after moving. The upload can be forged, so it's only used for the author of the posts it comes with, only when the real one can't be fetched, never with its key (it would let anyone sign as that actor), and it's marked as unverified.
  defp maybe_create_gone_author(%{"id" => id} = actor, activities) when is_binary(id) do
    with true <- Enum.any?(activities, &(e(&1, "object", "attributedTo", nil) == id)),
         {:error, _} <- ActivityPub.Actor.get_cached_or_fetch(ap_id: id) do
      actor
      |> Map.delete("publicKey")
      |> ActivityPub.Actor.create_or_update_actor_from_object(
        already_fetched: true,
        authenticated: :unverified
      )
      |> debug("created the gone author from the archive")
    end
  end

  defp maybe_create_gone_author(_, _), do: nil

  @doc "Imports the old account's profile, from its actor document: only what this profile doesn't have yet, never the name, and the avatar and banner from the archive's own copies."
  def import_profile(user, %{} = actor, staged_dir) do
    user = repo().maybe_preload(user, profile: [:icon, :image])
    profile = e(user, :profile, nil)

    text =
      %{
        "summary" => if(blank?(e(profile, :summary, nil)), do: actor["summary"]),
        "location" =>
          if(blank?(e(profile, :location, nil)),
            do:
              e(actor, "location", "name", nil) ||
                (is_binary(actor["location"]) && actor["location"]) || nil
          )
      }
      |> Enums.filter_empty(%{})

    with {:ok, user} <-
           if(text == %{}, do: {:ok, user}, else: Users.update(user, %{"profile" => text})) do
      for {kind, field, uploader} <- [
            {:icon, :icon_id, Bonfire.Files.IconUploader},
            {:banner, :image_id, Bonfire.Files.BannerUploader}
          ],
          is_nil(e(profile, field, nil)),
          url = e(actor, if(kind == :icon, do: "icon", else: "image"), "url", nil),
          path = is_binary(staged_dir) && staged_attachment_path(staged_dir, %{"url" => url}),
          is_binary(path) do
        with {:ok, media} <-
               Bonfire.Files.upload(uploader, user, path, %{client_name: Path.basename(path)}) do
          Bonfire.Me.Profiles.set_profile_image(kind, user, media)
        end
      end

      :ok
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""

  @doc """
  Imports one outbox activity, for the scope: called by `Bonfire.Common.Import`'s worker for each queued job of an op in `import_ops/0`.

  ## Examples

      iex> perform_import("outbox_creations_import", activity, current_user: user)

  """
  @impl Bonfire.Common.ImportModule
  def perform_import("outbox_creations_import" = op, identifier, scope) do
    with {:ok, _boost} <-
           process_json_activity(identifier, Utils.current_user(scope),
             include_boosts: false,
             media_dir: scope[:media_dir]
           ) do
      :ok
    else
      error -> Bonfire.Common.Import.handle_error(op, identifier, error)
    end
  end

  def perform_import("outbox_import" = op, identifier, scope) do
    with {:ok, _boost} <-
           process_json_activity(identifier, Utils.current_user(scope),
             include_boosts: true,
             media_dir: scope[:media_dir]
           ) do
      :ok
    else
      error -> Bonfire.Common.Import.handle_error(op, identifier, error)
    end
  end

  # whether a post names an attachment by a path rather than a URL (as in a Mastodon archive) with no copy of it staged, so the embedded copy would import without it
  defp missing_relative_attachments?(%{} = object, media_dir) do
    object
    |> Map.get("attachment")
    |> List.wrap()
    |> Enum.any?(fn
      %{"type" => "Link"} ->
        false

      %{"url" => url} = attachment when is_binary(url) ->
        URI.parse(url).host in [nil, ""] and
          (is_nil(media_dir) or is_nil(staged_attachment_path(media_dir, attachment)))

      _ ->
        false
    end)
  end

  defp process_json_activity(
         %{"type" => "Create", "object" => %{"id" => object_id} = object} = activity,
         user,
         opts
       ) do
    media_dir = opts[:media_dir]

    cond do
      addressed_to_nobody?(activity) ->
        import_for_importer_only(activity, user, media_dir)

      missing_relative_attachments?(object, media_dir) and
          not match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: object_id)) ->
        # the origin's copy names its pictures by URL, so fetch it, and keep the embedded copy (without pictures) when the origin doesn't answer
        case ImportOps.import_object_action(:boost_imported_post, object_id, activity, user) do
          {:ok, _} = done ->
            done

          other ->
            warn(
              other,
              "Could not fetch #{object_id} for its pictures, importing it without them"
            )

            import_embedded_create(activity, object_id, user, media_dir)
        end

      true ->
        import_embedded_create(activity, object_id, user, media_dir)
    end
  end

  defp process_json_activity(%{"type" => "Create", "object" => object} = activity, user, _) do
    # For other Create activities where we don't have the full object, fetch the object before boosting
    with {:ok, boost} <-
           ImportOps.import_object_action(:boost_imported_post, object, activity, user) do
      if object = e(boost, :edge, :object, nil) || e(boost, :edge, :object_id, nil),
        do: maybe_fetch_thread_async(object, user |> repo().maybe_preload(:settings))

      {:ok, boost}
    end
  end

  defp process_json_activity(
         %{"type" => "Announce", "object" => object} = activity,
         user,
         opts
       ) do
    if opts[:include_boosts] do
      ImportOps.import_object_action(:boost, object, activity, user)
    else
      debug(activity, "Skipping a boost, since boosts weren't asked for")
      {:ok, nil}
    end
  end

  defp process_json_activity(%{"type" => type} = activity, _user, _) do
    msg = "Skipping unsupported activity type: #{type}"
    debug(activity, msg)
    {:ok, nil}
  end

  defp process_json_activity(invalid_activity, _user, _)
       when is_nil(invalid_activity) or invalid_activity == %{} or invalid_activity == "" do
    msg = "Skipping empty activity"
    debug(invalid_activity, msg)
    {:ok, nil}
  end

  defp process_json_activity(invalid_activity, _user, _) do
    msg = "Skipping unsupported activity structure"
    debug(invalid_activity, msg)
    {:ok, nil}
  end

  # A post of the person's own that was addressed to nobody: it comes in for them alone. Its boundary is set to just them, and it's boosted onto their profile without federating, so nothing about it reaches other servers
  defp import_for_importer_only(activity, user, media_dir) do
    # inserted with its addressing as it is, empty, so it comes in as a post (one with recipients would become a message), which the boundaries MRF accepts for this import alone
    with {:ok, inserted} <-
           maybe_insert_embedded_object(activity, user, media_dir, own_post_to_nobody: true),
         {:ok, post} <- pointable(inserted, user) do
      keep_to_importer_and_boost(post, user)
    end
  end

  # sets the post's boundary to just the importer, then boosts it onto their profile without federating
  defp keep_to_importer_and_boost(post, user) do
    with {_num, nil} <- Bonfire.Boundaries.Controlleds.remove_all_acls(post),
         # the importer as the creator: it's their own post, from their old account
         {:ok, _} <-
           Bonfire.Boundaries.Acls.set(post, user,
             boundary: "custom",
             to_circles: [Enums.id(user)]
           ) do
      ImportOps.do_object_action(:boost, post, nil, user)
    end
  end

  # a non-public post that isn't for its author's followers, and whose recipients this instance doesn't know (eg. a direct message to an account that's gone): nobody but its author could see it
  defp seen_by_nobody_else?(%{"object" => %{} = object} = activity) do
    not ActivityPub.Utils.public?(activity, object) and
      not AdapterUtils.addressed_to_author_followers?(activity) and
      AdapterUtils.all_known_recipient_characters(activity, object) == []
  end

  defp seen_by_nobody_else?(_), do: false

  defp pointable(%ActivityPub.Object{} = ap_object, user),
    do: AdapterUtils.return_pointable(ap_object, current_user: user, verbs: [:boost])

  defp pointable(pointer_id, _user) when is_binary(pointer_id),
    do: Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true)

  defp pointable(%{id: _} = pointable, _user), do: {:ok, pointable}

  defp import_embedded_create(activity, _object_id, user, media_dir) do
    # For Create activities with embedded objects, insert them directly without re-fetching
    with {:ok, inserted} <-
           maybe_insert_embedded_object(activity, user, media_dir) |> debug("created_object"),
         # an object this instance already had (a re-import, or a post fetched before) comes back as its pointer id
         {:ok, post} <- pointable(inserted, user) do
      # the recipients are only known once it's ingested (that fetched them), so this is decided here rather than before
      if seen_by_nobody_else?(activity),
        do: keep_to_importer_and_boost(post, user),
        else: ImportOps.do_object_action(:boost_imported_post, post, nil, user)
    end
  end

  # Helper to optionally fetch thread based on user setting
  defp maybe_fetch_thread_async(object, user) do
    debug(user, "user settings check for fetch_thread_on_import")

    if Settings.get(
         [__MODULE__, :fetch_threads_on_import],
         false,
         current_user: user,
         name: l("Fetch thread replies on import"),
         description: l("Automatically fetch replies when importing posts.")
       ) do
      debug("scheduling fetch_thread_async for imported object")
      fetch_thread_async(object, user)
    end
  end

  defp fetch_thread_async(object, user) do
    # TODO: configurable whether user wants to do this?
    ActivityPub.Federator.Fetcher.fetch_thread(
      object,
      user_id: Enums.id(user),
      # TODO: clean/document these?
      mode: :async,
      fetch_collection: :async,
      fetch_collection_entries: :async,
      triggered_by: "import:fetch_thread_async"
    )
    |> debug("called fetch_thread_async")
  end

  # Inserts an embedded JSON object directly into the ActivityPub database: `{:ok, inserted}` (its pointer, or the cached object), or an error
  defp maybe_insert_embedded_object(
         %{"object" => %{"id" => object_id} = object} = activity,
         user,
         media_dir,
         insert_opts \\ []
       ) do
    # Check if object already exists in cache
    case ActivityPub.Object.get_cached(ap_id: object_id) do
      {:ok, existing_object} ->
        debug(object_id, "Object already exists in cache")

        {:ok,
         e(existing_object, :pointer, nil) || e(existing_object, :pointer_id, nil) ||
           existing_object}

      {:error, :not_found} ->
        debug(object_id, "Object not cached, inserting embedded object directly")

        # Insert the embedded object directly (without re-fetching)
        with {:ok, inserted_object} <-
               ActivityPub.Federator.Fetcher.cached_or_handle_incoming(
                 activity,
                 [already_fetched: true, triggered_by: "import:embedded_object"] ++ insert_opts
               ) do
          maybe_fetch_thread_async(inserted_object, user)
          |> debug("Successfully inserted embedded object + scheduled thread fetching")

          inserted =
            e(inserted_object, :pointer, nil) || e(inserted_object, :pointer_id, nil) ||
              inserted_object

          maybe_attach_staged_media(user, inserted, object, media_dir)

          {:ok, inserted}
        else
          error ->
            error(error, "Failed to insert embedded object #{object_id}")
        end

      error ->
        error(error, "Error checking cache for #{object_id}")
    end
  end

  # an archive's own copy of each picture, attached to the post it came with. The copy wins over the origin's, which may be gone, so the post was inserted without it (a path isn't a URL `ap_receive_attachments` takes)
  defp maybe_attach_staged_media(user, post, %{} = object, media_dir) when is_binary(media_dir) do
    for attachment <- List.wrap(object["attachment"]),
        path = staged_attachment_path(media_dir, attachment),
        is_binary(path) do
      Bonfire.Files.ap_receive_local_attachment({user, post}, path, attachment)
      |> debug("attached staged media")
    end
  end

  defp maybe_attach_staged_media(_user, _post, _object, _media_dir), do: nil

  # where an attachment's file is in the staged dir: a relative `url` by its path (Mastodon writes it with a leading slash, the zip entry has none), an absolute one by `host/path`, then by `path`. A `Link` (eg. to a quoted post) is not a file.
  defp staged_attachment_path(_media_dir, %{"type" => "Link"}), do: nil

  defp staged_attachment_path(media_dir, %{"url" => url}) when is_binary(url) do
    uri = URI.parse(url)
    path = String.trim_leading(uri.path || "", "/")

    candidates =
      if uri.host in [nil, ""],
        do: [path],
        else: [Path.join(uri.host, path), path]

    Enum.find_value(candidates, fn relative ->
      with {:ok, safe} <- Path.safe_relative(relative),
           full = Path.join(media_dir, safe),
           {:ok, %{type: :regular}} <- File.lstat(full) do
        full
      else
        _ -> nil
      end
    end)
  end

  defp staged_attachment_path(_media_dir, _attachment), do: nil
end
