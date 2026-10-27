defmodule Bonfire.Federate.ActivityPub.Incoming do
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  import ActivityPub.Config
  import Bonfire.Federate.ActivityPub
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  # import AdapterUtils, only: [log: 1]
  # alias Bonfire.Federate.ActivityPub.Adapter
  # alias Bonfire.Data.ActivityPub.Peered

  # the following constants are derived from config, so please make any changes/additions there

  @creation_verbs ["Create"]

  # Our own activities that took effect when we made them, so a group relaying them back to us changes nothing here (see the `receive_activity/1` clause that reads this)
  # TODO: a moderated group may want our post held until the group accepts and relays it (`apply_now: false` for a `Create`, as for our moderation there); a relayed-back `Create` that is waiting then has to be applied, as moderation is through `Moderations.confirm_applied/2`, while one already applied still must not
  @applied_when_made ["Create", "Update"]

  # Engagement-ping activity types (e.g. PeerTube `View`) that Bonfire does not model. We skip these cleanly instead of letting them fall through to the fallback store, which tried to persist them and crashed with a DB error that the Oban worker then retried 3×. See #1802.
  # Compile-time config so it can be used directly in the guard below (override in config).
  @skip_activity_types Application.compile_env(
                         :bonfire_federate_activitypub,
                         :skip_activity_types,
                         ["View", "Listen", "WatchAction"]
                       )

  def receive_activity(activity_id) when is_binary(activity_id) do
    info("AP - load the activity data from ID")

    ActivityPub.Object.get_cached!(id: activity_id)
    |> receive_activity()
  end

  def receive_activity(%{data: %{"type" => type}} = activity)
      when type in @skip_activity_types do
    # short-circuit before any actor/object fetch or store
    debug(activity, "AP - '#{type}' activity is not modelled by Bonfire, skipping cleanly")
    {:ok, :skip}
  end

  # One of ours, relayed back by a group hosted elsewhere (FEP-1b12), that took effect when we made it: applying it again would publish it again, which the group would announce again, and so on. Our moderation of a group hosted elsewhere is not in the list: unless it was applied at once (`apply_now`), it waits for the group, and the relayed copy is what applies it (`Moderations.confirm_applied/2`).
  def receive_activity(%{local: true, relayed_by: relayed_by, data: %{"type" => type}} = activity)
      when is_binary(relayed_by) and type in @applied_when_made do
    debug(
      activity.data["id"],
      "AP - one of ours relayed back by #{relayed_by}, already applied here"
    )

    {:ok, :already_applied}
  end

  def receive_activity(
        %{
          is_object: true
        } = object
      ) do
    info("AP - case when an Object comes to us instead of an activity")

    receive_object(nil, object)
  end

  def receive_activity(%{"id" => _} = activity) when not is_map_key(activity, :data) do
    info(activity, "AP - case when the worker gives us activity or object JSON data")
    receive_activity(%{data: activity})
  end

  def receive_activity(
        %{
          object: %{id: _} = object
        } = activity
      ) do
    info("AP - case when the Object comes to us preloaded with the activity")

    receive_activity(activity, object)
  end

  def receive_activity(
        %{
          data: %{
            "target" => target_id
          }
        } = activity
      )
      when is_binary(target_id) do
    info(
      "AP - fetch the #{activity.data["id"]} activity's target_id data from URI when we only have an AP ID: #{target_id}"
    )

    case fetch_final_object(target_id,
           return_tombstones: e(activity.data, "type", nil) == "Delete"
         ) do
      {:ok, target} ->
        debug(target, "fetched target")

        receive_activity(
          Map.update(activity, :data, %{"target" => target}, &Map.put(&1, "target", target))
        )
        |> debug("received activity on #{repo()}...")

      _ ->
        {:error, :not_found}
    end
  end

  def receive_activity(
        %{
          data: %{
            "object" => object_id
          }
        } = activity
      )
      when is_binary(object_id) do
    is_deleted? =
      is_in(e(activity.data, "type", nil), ["Delete", "Tombstone"])

    if is_deleted? and
         (object_id == e(activity.data, "actor", nil) or
            e(activity.data, "formerType", nil) in ActivityPub.Config.supported_actor_types()) do
      debug(
        "AP - actor deletion, we skip re-fetching the object as that is done elsewhere #{repo()}"
      )

      receive_activity(activity, object_id)
      |> debug("received deletion activity on #{repo()}...")
    else
      info(
        "AP - fetch the #{activity.data["id"]} activity's object data from URI when we only have an AP ID: #{object_id}"
      )

      # info(activity, "activity")
      case fetch_final_object(object_id,
             return_tombstones: is_deleted?
           ) do
        {:ok, object} ->
          debug(object, "fetched object")

          receive_activity(activity, object)
          |> debug("received activity on #{repo()}...")

        {:error, :not_found} ->
          # if is_deleted? do
          #   receive_activity(activity, object_id)
          #   |> debug("received deletion activity on #{repo()}...")
          # else
          error(object_id, "Could not fetch the activity's object")

        # end

        e ->
          error(e)
      end
    end
  end

  def receive_activity(
        %{
          data: %{
            "object" => [object_id_1 | _] = object_ids
          }
        } = activity
      )
      when is_binary(object_id_1) do
    info(
      "AP - we have a list of object IDs - fetch the #{activity.data["id"]} activity's object data from URIs when we only have AP IDs: #{inspect(object_ids)}"
    )

    # info(activity, "activity")
    for object_id <- object_ids do
      with {:ok, o} <-
             fetch_final_object(object_id,
               return_tombstones: e(activity.data, "type", nil) == "Delete"
             ) do
        o
      end
    end
    |> case do
      [{:error, something} | _] = errors ->
        error(errors, "Could not fetch object(s)")
        {:error, something}

      objects ->
        debug(objects, "fetched objects")

        receive_activity(activity, objects)
        |> debug("received activity on #{repo()}...")
    end
  end

  def receive_activity(
        %{
          data: %{
            "object" => object
          }
        } = activity
      ) do
    info("AP - case #1 when the object comes to us embedded in the activity")

    receive_activity(activity, object)
  end

  def receive_activity(
        %{
          data: %{
            "id" => _
          }
        } = activity
      ) do
    info("AP - case #2 when the activity has no `object` (like with Question)")

    receive_activity(activity, nil)
  end

  def receive_activity(activity, object) when is_map(object) and not is_map_key(object, :data) do
    info("AP - case #3 when the object comes to us embeded in the activity")
    receive_activity(activity, %{data: object})
  end

  # Activity: Update + Object: actor/character (local C2S — use object body directly)
  def receive_activity(
        %{local: true, data: %{"type" => "Update"}} = _activity,
        %{data: %{"type" => object_type, "id" => ap_id} = object_data} = _object
      )
      when is_in(object_type, :supported_actor_types) do
    info("AP Match#0a - update local actor from C2S body")

    with {:ok, actor} <- ActivityPub.Actor.get_cached(ap_id: ap_id),
         {:ok, actor} <-
           Bonfire.Federate.ActivityPub.Adapter.update_local_actor(actor, object_data) do
      {:ok, actor}
    end
  end

  # Activity: Update + Object: actor/character (remote — re-fetch from network)
  def receive_activity(
        %{data: %{"type" => "Update"}} = _activity,
        %{data: %{"type" => object_type, "id" => ap_id}} = _object
      )
      when is_in(object_type, :supported_actor_types) do
    info("AP Match#0b - update remote actor")

    with {:ok, actor} <- ActivityPub.Actor.get_cached(ap_id: ap_id),
         {:ok, actor} <-
           Bonfire.Federate.ActivityPub.Adapter.update_remote_actor(actor) do
      {:ok, actor}
    end
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        %{data: %{"type" => object_type}} = object
      )
      when is_binary(activity_type) and (is_binary(object_type) or is_list(object_type)) do
    info(object_type, "AP Match#1 - with activity_type: #{activity_type} and object_type:")

    fallback_module = fallback_federation_module()

    with {:ok, subject} <- AdapterUtils.activity_character(activity) |> info("activity_character"),
         # a type claimed via `APActivities.handle_object_types` is kept whole, beating any module handling one of the document's OTHER types: e.g. when configure in :handle_object_types a recipe with type `["Note", "Preparation"]` is a Preparation we keep as APActivity, not a Post with the recipe discarded
         {:no_federation_module_match, _} <-
           if(handled_as_ap_activity?(object_type, fallback_module),
             do: handle_activity_with({:ok, fallback_module}, subject, activity, object),
             else: {:no_federation_module_match, "no type handled as an APActivity"}
           ),
         {:no_federation_module_match, _} <-
           if(activity_type && object_type,
             do:
               handle_activity_with(
                 Bonfire.Federate.ActivityPub.FederationModules.federation_module(
                   {activity_type, object_type}
                 )
                 |> info("AP attempt #1.1 - with activity_type and object_type"),
                 subject,
                 activity,
                 object
               ),
             else: {:no_federation_module_match, "missing activity+object types"}
           ),
         # e.g. an Add/Remove targeting a known collection type (featured, …) → route by
         # {activity_type, target_collection_type} so the owning module (e.g. Pins) handles it
         {:no_federation_module_match, _} <-
           if(collection_target_type = collection_target_type(activity),
             do:
               handle_activity_with(
                 Bonfire.Federate.ActivityPub.FederationModules.federation_module(
                   {activity_type, collection_target_type}
                 )
                 |> info("AP attempt #1.1b - with activity_type and target collection type"),
                 subject,
                 activity,
                 object
               ),
             else: {:no_federation_module_match, "missing collection target type"}
           ),
         # just activity type
         {:no_federation_module_match, _} <-
           if(activity_type,
             do:
               handle_activity_with(
                 Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type)
                 |> info("AP attempt #1.2 - with activity_type"),
                 subject,
                 activity,
                 object
               ),
             else: {:no_federation_module_match, "missing activity type"}
           ),
         # just object type
         {:no_federation_module_match, _} <-
           if(object_type,
             do:
               handle_activity_with(
                 Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type)
                 |> info("AP attempt #1.3 - with object_type"),
                 subject,
                 activity,
                 object
               ),
             else: {:no_federation_module_match, "missing object type"}
           ) do
      receive_activity_fallback(activity, object, subject)
    else
      {:error, :not_found} ->
        if is_in(activity_type, ["Delete", "Tombstone"]) do
          # A Delete arrived for an actor (and object) we don't know locally — e.g. a
          # remote account deletion we never saw. Nothing to delete, so skip cleanly
          # rather than erroring (which the Oban worker would retry 3x). See #1784.
          debug(
            activity,
            "AP - Delete from an actor we don't know locally, skipping (nothing to delete)"
          )

          {:ok, :skip}
        else
          {:error, :not_found}
        end

      other ->
        other
    end
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        object_or_objects
      )
      when is_binary(activity_type) do
    info("AP Match#2 - by activity_type only: #{activity_type}")

    with {:ok, subject} <- AdapterUtils.activity_character(activity),
         # For actor deletion: check if we only have an ap_id for the object, and if it matches the subject's ap_id, and if so use subject as object 
         subject_as_object =
           if(
             is_binary(object_or_objects) and
               object_or_objects ==
                 (e(activity.data, "actor", "id", nil) || e(activity.data, "actor", nil)),
             do: subject
           ),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type),
             subject,
             activity,
             subject_as_object || object_or_objects
           ) do
      receive_activity_fallback(activity, subject_as_object || object_or_objects, subject)
    end
  end

  def receive_activity(
        activity,
        %{data: %{"type" => object_type}} = object
      )
      when is_binary(object_type) or is_list(object_type) do
    info(object_type, "AP Match#3 - by object_type only")

    with {:ok, subject} <- AdapterUtils.activity_character(activity),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type),
             subject,
             activity,
             object
           ) do
      receive_activity_fallback(activity, object, subject)
    end
  end

  def receive_activity(activity, object) do
    info("AP no match - receive_activity_fallback")

    receive_activity_fallback(activity, object)
  end

  # The collection "type" of an activity's `target` (e.g. "featured"), for dispatch-by-target, determined by which collection property on the *actor* points at the target. Works for our own ids and remote/Mastodon (`{actor}/collections/featured`) alike. `target` and `actor` were already resolved into the activity by earlier `receive_activity/1` clauses.
  defp collection_target_type(%{data: %{"target" => target} = data}) do
    with target_id when is_binary(target_id) <- AdapterUtils.collection_target_id(target) do
      # `get_cached` deliberately, never a fetch: an addressing field must not be able to make us fetch arbitrary URLs, and a collection owner we have never seen is not one we mirror anyway
      Enum.find_value(AdapterUtils.collection_owner_candidates(data), fn candidate ->
        with {:ok, %{data: actor_data}} when is_map(actor_data) <-
               ActivityPub.Actor.get_cached(ap_id: candidate) do
          # the type is the actor property whose value is the target id (e.g. "featured",
          # "keyPackages", or "attributedTo" for a community's moderators)
          Enum.find_value(actor_data, fn
            {key, value} when is_binary(value) and value == target_id -> key
            _ -> nil
          end)
        else
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp collection_target_type(_), do: nil

  defp fetch_final_object(object_id, opts) do
    case ActivityPub.Federator.Fetcher.get_cached_or_fetch_object(
           object_id,
           opts |> Keyword.put(:triggered_by, "Incoming.fetch_final_object")
         ) do
      # support receiving an activity when we're expecting an object (eg for a flag or a like)
      {:ok, %{data: %{"type" => "Create", "object" => actual_object_id}}}
      when is_binary(actual_object_id) and actual_object_id != object_id ->
        fetch_final_object(actual_object_id, opts)

      {:ok, %{"type" => "Create", "object" => actual_object_id}}
      when is_binary(actual_object_id) and actual_object_id != object_id ->
        fetch_final_object(actual_object_id, opts)

      {:ok, object} ->
        {:ok, object}

      other ->
        error(other)
    end
  end

  defp fallback_federation_module,
    do:
      Bonfire.Common.Config.get(
        [__MODULE__, :federation_fallback_module],
        Bonfire.Social.APActivities
      )

  # does the document declare a type listed in `APActivities`' `handle_object_types`, i.e. one we store whole as an APActivity instead of mapping onto a native type? Asks the module directly rather than the registry, which is cached and so would not see a config change
  defp handled_as_ap_activity?(object_type, fallback_module \\ fallback_federation_module()) do
    claimed =
      maybe_apply(fallback_module, :federation_module, [], fallback_return: [])
      |> List.wrap()

    Enum.any?(List.wrap(object_type), &(&1 in claimed))
  end

  defp receive_activity_fallback(activity, object, subject \\ nil) do
    module = fallback_federation_module()

    if module do
      info("AP - handling activity with fallback module")
      # module.create(actor, activity, object)
      handle_activity_with(
        {:ok, module},
        subject,
        activity,
        object
      )
    else
      error = "ActivityPub - ignored incoming activity - unhandled activity or object type"

      no_federation_module_match("#{error}")
      info("AP activity: #{inspect(activity, pretty: true)}")
      info("AP object: #{inspect(object, pretty: true)}")
      {:error, error}
    end
  end

  @doc """
  Create an object without an activity
  """
  def receive_object(_creator, object_uri) when is_binary(object_uri) do
    info("AP - Create an object from AP ID")

    receive_activity(%{
      data: %{
        "object" => object_uri
      }
    })
  end

  def receive_object(creator, object) do
    info("AP - Create an object without an activity")

    # with no creator given (eg. re-ingesting a cached object not yet linked to a local one) the author is the object's own `attributedTo`, else the service character would be credited
    receive_activity(
      %{
        data: %{
          "type" => "Create",
          "actor" => creator || ActivityPub.Object.actor_id_from_data(object)
        }
      },
      object
    )
  end

  # for activities that create new objects we need to take into account the date, and save canonical url/update pointer
  # This should not be done if the object is local, i. e. local actor as the object of a follow
  # Creates the local object only if none exists yet for the AP id, else returns the existing one. Two jobs can ingest the same object at once (eg. a Note's `Create` from its author's inbox delivery, and a relay's `Announce` of it, which resolves the Note before the first job has linked it): both would pass the exists? check before either commits, and each create a Post. So the check and the creation run under a lock on the AP id, and the job that waited finds the Post the other created.
  defp handle_activity_with(
         {:ok, module},
         character,
         %{data: %{"type" => verb}} = activity,
         object
       )
       when is_atom(module) and not is_nil(module) and
              (verb in @creation_verbs or
                 is_in(verb, :supported_intransitive_types) == true) do
    ap_obj_id = e(object, :data, "id", nil)
    ap_activity_id = e(activity, :data, "id", nil)
    ap_id = ap_obj_id || ap_activity_id

    lock_id = if(ap_id, do: {__MODULE__, :ingest, ap_id})

    Utils.with_lock(lock_id, fn ->
      create_unless_exists(ap_id, module, character, activity, object)
    end)
  end

  # the exists? check and the creation, which `handle_activity_with/4` runs under the AP id's lock
  defp create_unless_exists(ap_id, module, character, activity, object) do
    if ap_id && Bonfire.Common.Needles.exists?(ap_id) do
      warn(ap_id, "Already exists locally")
      Bonfire.Common.Needles.get(ap_id, skip_boundary_check: true)
    else
      local? = e(activity, :local, false)

      previous_pointer_id = e(object, :pointer_id, nil)

      # a placeholder that replies to it are threaded under (`AdapterUtils.get_or_create_placeholder/1`): it is created under that id, so they stay where they are
      placeholder_id = if !local?, do: AdapterUtils.placeholder_id(ap_id)

      pointer_id =
        placeholder_id ||
          if local? do
            debug("activity is local (prob processed via C2S)")

            # TODO: better architecture, maybe updating these instead of deleting?

            if pointer_id = AdapterUtils.pointer_id_from_url(ap_id) do
              # set pointer ID to the same one as was initially created in AP db
              pointer_id
            end
          end ||
          with published when is_binary(published) <-
                 e(object, :data, "published", nil) || e(activity, :data, "published", nil),
               # dated by the same rule as its AP row (`ActivityPub.Utils.published_at/2`): one we fetched from its origin keeps its date however old, one delivered to us only within a range, so a sender cannot float or bury a post with a date it chose
               %DateTime{} = date <-
                 ActivityPub.Utils.published_at(published, received_as(activity, object)) do
            DatesTimes.generate_ulid(date)
            # DatesTimes.date_from_pointer(pointer_id) |> debug("date from pointer")
          else
            _ -> nil
          end

      debug(
        "AP - handle_activity_with OK: #{module} to Create #{ap_id} as #{inspect(pointer_id)} using #{module}"
      )

      fallback_module = fallback_federation_module()

      # A local C2S activity is not federated by `ActivityPub.create/2` (which skips `maybe_federate` when `from_c2s`), so it has to be published from here, but it still needs a local object first: the `ActivityPub.Object` stored by `Object.insert` is not a pointable and never reaches a feed.
      publish_after_create? = local? and module == fallback_module

      if placeholder_id, do: prepare_placeholder_fill(placeholder_id)

      with {:ok, %{id: pointable_object_id, __struct__: type} = pointable_object} <-
             Utils.maybe_apply(
               module,
               :ap_receive_activity,
               ap_receive_args(
                 module,
                 [
                   character,
                   if(not is_map(object),
                     do: Map.merge(activity, %{pointer_id: pointer_id}),
                     else: activity
                   ),
                   if(is_map(object), do: Map.merge(object, %{pointer_id: pointer_id}))
                 ],
                 activity,
                 object
               ),
               no_argument_rescue: true,
               fallback_fun: &no_federation_module_match/2
             )
             |> debug("attempted creation of object") do
        debug(
          "AP - created object with local ID #{pointable_object_id} of type #{inspect(type)} for #{ap_id}"
        )

        if placeholder_id == pointable_object_id, do: fill_placeholder(placeholder_id, type)

        link_ap_object(object, pointable_object_id,
          activity: activity,
          ap_id: ap_id,
          local?: local?,
          previous_pointer_id: previous_pointer_id
        )

        maybe_apply_comments_enabled(character, object, pointable_object_id)

        # replies that reached us before this object did, now that it is linked to its AP object
        Utils.maybe_apply(Bonfire.Social.Threads, :adopt_orphaned_replies, [
          pointable_object,
          object
        ])

        if publish_after_create? do
          info("Local C2S activity handled by the fallback module, federating it now")
          ActivityPub.Federator.publish(activity)
        end

        {:ok, pointable_object}
      else
        {:ok, :skipped} ->
          debug(ap_id, "AP - object skipped (no Bonfire record needed)")
          if placeholder_id, do: restore_placeholder(placeholder_id)
          {:ok, :skipped}

        e ->
          debug(e, "Could not create object")
          if placeholder_id, do: restore_placeholder(placeholder_id)

          error(
            "Could not create object for #{ap_id}: #{Types.to_string_or_inspect(Errors.error_msg(e))}"
          )

          # throw({:error, "Could not process incoming activity"})
      end
    end
  end

  # how a remote post reached us, for `ActivityPub.Utils.published_at/2`: fetched from its origin (its AP copy, or the activity's, marked so), else delivered
  # fetched from its origin, or vouched for by its author's own proof or LD signature: either way its date is the author's word, as `ActivityPub.Utils.arrival/3` has it for the AP row
  defp received_as(activity, object) do
    if Enum.any?(
         [e(object, :authenticated, nil), e(activity, :authenticated, nil)],
         &(&1 in [:fetched, :integrity_proof, :ld_signature])
       ),
       do: :fetched,
       else: :delivered
  end

  defp handle_activity_with(
         {:ok, module},
         character,
         %{data: %{"type" => verb}} = activity,
         object
       )
       when is_atom(module) and not is_nil(module) and is_in(verb, ["Accept", "Reject"]) do
    info(
      "AP - Accept/Reject (related to another activity) handle_activity_with module: #{module}"
    )

    with {:ok, %{id: _pointable_object_id} = pointable_object} <-
           Utils.maybe_apply(
             module,
             :ap_receive_activity,
             [character, activity, object],
             no_argument_rescue: true,
             fallback_fun: &no_federation_module_match/2
           ) do
      {:ok, pointable_object}
    end
  end

  # An `Update` of something with no AP row: pruned, or never seen (eg. PeerTube's `Update{Video}`, sent each time a video gets views, for a video we never fetched). The module updates what we hold for its AP id, found as the module would find a pruned post (`AdapterUtils.pointer_id_from_ap_object/1`). When we hold nothing it is a first sighting, made once under the same lock as a `Create` (`create_unless_exists/5`): before, each such `Update` made another copy, as nothing was stored for the next one to find. Made only from its owner, as an `Update` reaches here without the lib's checks on what it embeds
  defp handle_activity_with(
         {:ok, module},
         character,
         %{data: %{"type" => "Update"} = activity_data} = activity,
         %{data: %{"id" => ap_id} = object_data} = object
       )
       # an embedded object reaches here as a plain map, with no `pointer_id` key at all
       when is_atom(module) and not is_nil(module) and is_binary(ap_id) and
              (not is_map_key(object, :pointer_id) or
                 :erlang.map_get(:pointer_id, object) == nil) do
    case AdapterUtils.pointer_id_from_ap_object(object) do
      pointer_id when is_binary(pointer_id) ->
        # with its id, so the clause below handles it
        handle_activity_with(
          {:ok, module},
          character,
          activity,
          Map.put(object, :pointer_id, pointer_id)
        )

      _ ->
        if activity_data["actor"] in owner_ids(object_data) do
          Utils.with_lock({__MODULE__, :ingest, ap_id}, fn ->
            create_unless_exists(
              ap_id,
              module,
              character,
              Map.update!(activity, :data, &Map.put(&1, "type", "Create")),
              object
            )
          end)
        else
          error(ap_id, "an Update of something we do not hold, from someone other than its owner")
        end
    end
  end

  defp handle_activity_with({:ok, module}, character, activity, object)
       when is_atom(module) and not is_nil(module) do
    info(activity, "AP - handle_activity_with module: #{module}")

    # looked up before the module handles the activity: a deletion takes the object away, and with it the way to find its group. Not for an activity of ours that the group elsewhere echoes back (`local`), which only confirms what we sent
    announce_target =
      if e(activity, :local, nil) != true,
        do: AdapterUtils.group_announce_target_of_activity(activity)

    with {:ok, %struct{id: pointable_object_id} = pointable_object} <-
           Utils.maybe_apply(
             module,
             :ap_receive_activity,
             ap_receive_args(module, [character, activity, object], activity, object),
             no_argument_rescue: true,
             fallback_fun: &no_federation_module_match/2
           ) do
      # activity = ActivityPub.Object.normalize(activity)
      # ActivityPub.Object.update_existing(activity, %{pointer_id: pointable_object_id})
      # object = ActivityPub.Object.normalize(object)

      id =
        if struct not in [ActivityPub.Object, ActivityPub.Actor],
          do:
            Types.uid(pointable_object_id)
            |> debug("uiid")

      if id && !is_in(e(activity, :data, "type", nil), ["Update", "Delete"]) do
        with activity_id when not is_nil(activity_id) <- Enums.id(activity) do
          ActivityPub.Object.update_existing(activity_id, %{pointer_id: id})
        end
      end
      |> debug("pointer_id update")

      # an Update can also REOPEN a thread it previously closed, which a create cannot
      maybe_apply_comments_enabled(character, object, id || pointable_object_id,
        updating: e(activity, :data, "type", nil) == "Update"
      )

      {:ok, pointable_object}
    end
    |> announce_if_accepted(announce_target, activity)
  end

  # A group we host announces what happens in it (`AdapterUtils.group_announce_target_of_activity/1` says which activities and for what), whatever the object's type, so each type's module does not have to remember to. Only once the module accepted the activity: a stranger's `Update` or `Delete`, or a moderator the group refuses, is turned down and must not be announced as the group's. What "accepted" returns differs by module (a struct, a count, a status), so any `{:ok, _}` that is not a skip counts.
  defp announce_if_accepted({:ok, accepted} = result, announce_target, activity)
       when accepted not in [:skip, :skipped, :none, :ignore] do
    AdapterUtils.announce_by_group(announce_target, activity)
    result
  end

  defp announce_if_accepted(result, _announce_target, _activity), do: result

  # Which local groups an activity was addressed to is a property of the DELIVERY rather than of whatever the object turns out to be locally, so it is derived once here and handed to every handler, the same reasoning as `maybe_apply_comments_enabled/4` below. 
  # Only handlers that accept a 4th argument get it: `Utils.maybe_apply/4` picks the function by the arity of the args it is given, so passing four to a `/3` handler would find nothing and fall through to `no_federation_module_match/2` rather than degrading.
  # Takes the argument list a call site has already built (they differ: the creation path merges `pointer_id` into what it passes) and appends the derived opts to it.
  defp ap_receive_args(module, args, activity, object) do
    if Code.ensure_loaded?(module) and function_exported?(module, :ap_receive_activity, 4) do
      groups =
        (AdapterUtils.local_group_audiences(e(activity, :data, %{}), e(object, :data, %{})) ++
           List.wrap(AdapterUtils.mirrored_group(e(activity, :relayed_by, nil), create: true)))
        |> Enum.uniq_by(&Enums.id/1)
        |> debug("groups or topics this activity is addressed to or relayed by, if any")

      args ++ [[publish_in: Enums.ids(groups)]]
    else
      args
    end
  end

  # A thread's reply status can arrive ON THE OBJECT as `commentsEnabled` (the threadiverse's way of saying it, where a `Lock` activity says a change to it). Applied here rather than in each context module because it belongs to any threaded object, whatever it becomes locally: a `Post`, an `Article`, a poll `Question`, or the `Media` that a link post becomes.
  defp maybe_apply_comments_enabled(character, object, pointable_object_id, opts \\ []) do
    Utils.maybe_apply(
      Bonfire.Social.Threads,
      :ap_receive_comments_enabled,
      [{:ok, pointable_object_id}, character, e(object, :data, %{}), opts],
      fallback_return: nil
    )
  end

  # defp handle_activity_with(_module, {:error, _}, activity, _) do
  #   no_federation_module_match("AP - could not find local character for the actor", activity)
  # end

  defp handle_activity_with(module, _actor, _activity, _object) do
    warn(module, "AP - no match in handle_activity_with")
    # error(activity, "AP - no module defined to handle_activity_with activity")
    # error(object, "AP - no module defined to handle_activity_with object")
    {:no_federation_module_match, :ignore}
  end

  # who an object names as its owners: a PeerTube video names its account and its channel
  defp owner_ids(object_data) do
    (object_data["attributedTo"] || object_data["actor"])
    |> List.wrap()
    |> Enum.map(&ActivityPub.Object.get_ap_id/1)
    |> Enum.reject(&is_nil/1)
  end

  # Before the object is created under its placeholder's id: the object gets a `Replied` of its own in the placeholder's place, and the pointer is undeleted now rather than once it is created, as whoever is shown it as it is created (`Bonfire.Social.LivePush`, which runs in its creation) checks it exists
  defp prepare_placeholder_fill(id) do
    import Ecto.Query

    Utils.maybe_apply(Bonfire.Social.Threads, :unplace_placeholder, [id])

    from(p in Needle.Pointer, where: p.id == ^id)
    |> repo().update_all(set: [deleted_at: nil])
  end

  # its creation failed, so it is a placeholder again (soft-deleted, which only hard-deletes a row of its `APActivity` type, of which it has none), standing where it can without knowing its thread
  defp restore_placeholder(id) do
    import Ecto.Query

    from(p in Needle.Pointer, where: p.id == ^id)
    |> repo().update_all(set: [deleted_at: DateTime.utc_now()])

    Utils.maybe_apply(Bonfire.Social.Threads, :place_placeholder, [id])
  end

  # the object is created under its placeholder's id, whose pointer the creation keeps as it was (Needle's insert triggers do `on conflict do nothing` on it): so it is repointed to the object's type here, and what in its thread depends on where it landed is put right
  defp fill_placeholder(id, type) do
    import Ecto.Query

    from(p in Needle.Pointer, where: p.id == ^id)
    |> repo().update_all(set: [table_id: Needle.Tables.id!(type)])

    Utils.maybe_apply(Bonfire.Social.Threads, :placeholder_filled, [id])
  end

  @doc """
  Links an INCOMING AP object to the local object created from it: the `Peered` canonical URI, and the pointer on the `ap_object` row.

  Called from two places on purpose, and it is the same work either way. `Bonfire.Social.Acts.Federate` calls it INSIDE the creation epic, so later acts in that epic can resolve the object and federate it: that is what lets a group relay a post it has just accepted, and a remote post mentioning a local category be boosted into it. `receive_object/…` calls it afterwards for everything that never runs an epic (media, unrecognised activities), where it is the only link there is.

  The second call in an ingest costs a map lookup rather than two writes: both happen in the same process, so what has already been linked is remembered there.
  """
  def link_ap_object(object, pointer_id, opts \\ [])

  def link_ap_object(_object, nil, _opts), do: nil

  def link_ap_object(object, pointer_id, opts) do
    ap_id = opts[:ap_id] || e(object, :data, "id", nil) || e(object, "id", nil)

    # keyed on the ROW rather than the AP id: an `Update` for the same object arrives as a different `ap_object` row and still has to be linked, so keying on the id would skip it
    marker = {:ap_linked, id(object) || ap_id}

    # ⚠️ a nil object alone does NOT mean there is nothing to link: an activity with no object of its own (a `Question`) still has an `ap_object` row, which `maybe_set_pointer_on_ap_object/4` reaches through the activity. Only with neither is there nothing to do, which is how an epic creating an object with no incoming AP one (a locally composed poll) gets here
    cond do
      is_nil(object) and is_nil(opts[:activity]) ->
        debug(pointer_id, "no incoming AP object or activity to link this to")

      Process.get(marker) == pointer_id ->
        debug(ap_id, "already linked to its local object in this ingest, so nothing to do")

      true ->
        # a Peer for the instance and a Peered URI, for remote objects only
        if !opts[:local?] do
          Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(pointer_id, ap_id, type: :object)
          |> debug("saved canonical uri for peered object")
        end

        # attach the local pointer to the AP object (for both local C2S and remote)
        maybe_set_pointer_on_ap_object(
          object,
          opts[:activity],
          pointer_id,
          opts[:previous_pointer_id]
        )

        Process.put(marker, pointer_id)
    end
  end

  @doc """
  Ties an incoming AP object to the record just created for it, THEN tags that record (which files it into any groups among the tags, and auto-boosts them).

  For handlers that run no epic, and so get neither ordering for free. The order is the whole point: the group's auto-boost federates an `Announce` that resolves the boosted object through its AP object, so tagging first means the boost is published while nothing is linked yet, `Boosts.ap_publish_activity/3` finds no AP object, and the group relays nothing — silently, since a local boost is still created and everything looks filed from the inside.

  Epic-based handlers get the same ordering from `Bonfire.Social.Acts.Federate` (which links) running before `Bonfire.Tags.Acts.AutoBoost`.
  """
  def link_and_tag(ap_object, pointer_id, creator, tags, opts \\ []) do
    link_ap_object(ap_object, pointer_id, Keyword.put_new(opts, :local?, false))

    case List.wrap(tags) do
      [] ->
        nil

      tags ->
        Utils.maybe_apply(Bonfire.Tag, :maybe_tag, [creator, pointer_id, tags],
          fallback_return: nil
        )

        # tagging boosts it into the group's feed; publishing it IN the group (tree parent, and the group's ACLs, so its moderators can moderate it) is what the Tag act and `SetBoundaries` do for anything that runs an epic, which this object did not
        Utils.maybe_apply(
          Bonfire.Classify,
          :publish_existing_in,
          [pointer_id, creator, tags],
          fallback_return: nil
        )
    end
  end

  defp maybe_set_pointer_on_ap_object(object, activity, pointer_id, previous_pointer_id) do
    object_id = id(object) || id(activity)

    if object_id &&
         (is_nil(previous_pointer_id) or
            previous_pointer_id != pointer_id),
       do:
         ActivityPub.Object.update_existing(object_id, %{
           pointer_id: pointer_id
         })
         |> debug("pointer_id update")
  end

  def no_federation_module_match(error, attrs \\ nil) do
    error(
      attrs,
      "ActivityPub - Unable to process incoming federated activity - #{error}"
    )

    {:no_federation_module_match, {error, attrs}}
  end
end
