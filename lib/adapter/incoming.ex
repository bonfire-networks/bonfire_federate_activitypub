defmodule Bonfire.Federate.ActivityPub.Incoming do
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  import Bonfire.Federate.ActivityPub
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  # import AdapterUtils, only: [log: 1]
  # alias Bonfire.Search.Indexer
  # alias Bonfire.Federate.ActivityPub.Adapter
  # alias Bonfire.Data.ActivityPub.Peered

  # the following constants are derived from config, so please make any changes/additions there

  @creation_verbs ["Create"]
  @actor_types Application.compile_env(:bonfire, :actor_AP_types, [
                 "Person",
                 "Group",
                 "Application",
                 "Service",
                 "Organization"
               ])

  def receive_activity(activity_id) when is_binary(activity_id) do
    info("AP - load the activity data from ID")

    ActivityPub.Object.get_cached!(id: activity_id)
    |> receive_activity()
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

    case ActivityPub.Federator.Fetcher.get_cached_object_or_fetch_ap_id(target_id) do
      {:ok, target} ->
        debug(target, "fetched target")

        receive_activity(Map.update(activity, :data, %{}, &Map.put(&1, "target", target)))
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
    info(
      "AP - fetch the #{activity.data["id"]} activity's object data from URI when we only have an AP ID: #{object_id}"
    )

    # info(activity, "activity")
    case ActivityPub.Federator.Fetcher.get_cached_object_or_fetch_ap_id(object_id) do
      {:ok, object} ->
        debug(object, "fetched object")

        receive_activity(activity, object)
        |> debug("received activity on #{repo()}...")

      _ ->
        {:error, :not_found}
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
      with {:ok, o} <- ActivityPub.Federator.Fetcher.get_cached_object_or_fetch_ap_id(object_id) do
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
    info("AP - case #1 when the object comes to us embeded in the activity")

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

  # Activity: Update + Object: actor/character
  def receive_activity(
        %{data: %{"type" => "Update"}} = _activity,
        %{data: %{"type" => object_type, "id" => ap_id}} = _object
      )
      when object_type in @actor_types do
    info("AP Match#0 - update actor")

    with {:ok, actor} <- ActivityPub.Actor.get_cached(ap_id: ap_id),
         {:ok, actor} <-
           Bonfire.Federate.ActivityPub.Adapter.update_remote_actor(actor) do
      # Indexer.maybe_index_object(actor)
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
      when is_binary(activity_type) and is_binary(object_type) do
    info("AP Match#1 - with activity_type and object_type: #{activity_type} & #{object_type}")

    with {:ok, actor} <- activity_character(activity) |> info("activity_character"),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(
               {activity_type, object_type}
             )
             |> info("AP attempt #1.1 - with activity_type and object_type"),
             actor,
             activity,
             object
           ),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type)
             |> info("AP attempt #1.2 - with activity_type"),
             actor,
             activity,
             object
           ),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type)
             |> info("AP attempt #1.3 - with object_type"),
             actor,
             activity,
             object
           ) do
      receive_activity_fallback(activity, object, actor)
    end
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        object
      )
      when is_binary(activity_type) do
    info("AP Match#2 - by activity_type only: #{activity_type}")

    with {:ok, actor} <- activity_character(activity),
         {:error, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type),
             actor,
             activity,
             object
           ) do
      receive_activity_fallback(activity, object, actor)
    end
  end

  def receive_activity(
        activity,
        %{data: %{"type" => object_type}} = object
      )
      when is_binary(object_type) do
    info("AP Match#3 - by object_type only: #{object_type}")

    with {:ok, actor} <- activity_character(activity),
         {:error, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type),
             actor,
             activity,
             object
           ) do
      receive_activity_fallback(activity, object, actor)
    end
  end

  def receive_activity(activity, object) do
    info("AP no match - receive_activity_fallback")

    receive_activity_fallback(activity, object)
  end

  defp receive_activity_fallback(activity, object, actor \\ nil) do
    module = Application.get_env(:bonfire, :federation_fallback_module)

    if module do
      info("AP - handling activity with fallback")
      # module.create(actor, activity, object)
      handle_activity_with(
        {:ok, module},
        actor,
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
    receive_activity(%{data: %{"type" => "Create", "actor" => creator}}, object)
  end

  # for activities that create new objects we need to take into account the date, and save canonical url/update pointer
  # This should not be done if the object is local, i. e. local actor as the object of a follow
  defp handle_activity_with(
         {:ok, module},
         character,
         %{data: %{"type" => verb}} = activity,
         object
       )
       when is_atom(module) and not is_nil(module) and verb in @creation_verbs do
    info(character, "character")
    ap_obj_id = object.data["id"]

    if Bonfire.Common.Pointers.exists?(ap_obj_id) do
      error(ap_obj_id, "Already exists locally")
      Bonfire.Common.Pointers.get(ap_obj_id, skip_boundary_check: true)
    else
      pointer_id =
        with published when is_binary(published) <-
               object.data["published"] || activity.data["published"],
             {:ok, utc_date_published, _} <-
               DateTime.from_iso8601(published) |> info("date from AP"),
             # only if published in the past
             :lt <-
               DateTime.compare(utc_date_published, DateTime.now!("Etc/UTC")) do
          utc_date_published
          # |> info("utc_date_published")
          |> DateTime.to_unix(:millisecond)
          # |> info("to_unix")
          |> Pointers.ULID.generate()
        else
          _ -> nil
        end

      # DatesTimes.date_from_pointer(pointer_id) |> info("date from pointer")

      info(
        "AP - handle_activity_with OK: #{module} to Create #{ap_obj_id} as #{inspect(pointer_id)} using #{module}"
      )

      # info(object)

      with {:ok, %{id: pointable_object_id, __struct__: type} = pointable_object} <-
             Utils.maybe_apply(
               module,
               :ap_receive_activity,
               [
                 character,
                 activity,
                 Map.merge(object, %{pointer_id: pointer_id})
               ],
               no_argument_rescue: true,
               fallback_fun: &no_federation_module_match/2
             ) do
        info(
          "AP - created remote object with local ID #{pointable_object_id} of type #{inspect(type)} for #{ap_obj_id}"
        )

        # IO.inspect(pointable_object)

        # maybe save a Peer for instance and Peered URI
        Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
          pointable_object_id,
          ap_obj_id
        )

        # object = ActivityPub.Object.normalize(object)
        # FIXME
        if object &&
             (is_nil(object.pointer_id) or
                object.pointer_id != pointable_object_id),
           do:
             ActivityPub.Object.update_existing(object.id, %{
               pointer_id: pointable_object_id
             })
             |> info("pointer_id update")

        {:ok, pointable_object}
      else
        e ->
          error(
            Errors.error_msg(e),
            "Could not create activity for #{ap_obj_id}"
          )

          # throw({:error, "Could not process incoming activity"})
      end
    end
  end

  defp handle_activity_with(
         {:ok, module},
         character,
         %{data: %{"type" => verb}} = activity,
         object
       )
       when is_atom(module) and not is_nil(module) and verb in ["Accept", "Reject"] do
    info("AP - handle_activity related to another activity module: #{module}")

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

  defp handle_activity_with({:ok, module}, character, activity, object)
       when is_atom(module) and not is_nil(module) do
    info("AP - handle_activity_with module: #{module}")

    with {:ok, %{id: pointable_object_id} = pointable_object} <-
           Utils.maybe_apply(
             module,
             :ap_receive_activity,
             [character, activity, object],
             no_argument_rescue: true,
             fallback_fun: &no_federation_module_match/2
           ) do
      # activity = ActivityPub.Object.normalize(activity)
      # ActivityPub.Object.update_existing(activity, %{pointer_id: pointable_object_id})
      # object = ActivityPub.Object.normalize(object)

      id = Types.ulid(pointable_object_id)

      if id && e(activity, :data, "type", nil) != "Update" do
        ActivityPub.Object.update_existing(Enums.id(activity) || Enums.id(object), %{
          pointer_id: id
        })
      end

      {:ok, pointable_object}
    end
  end

  # defp handle_activity_with(_module, {:error, _}, activity, _) do
  #   no_federation_module_match("AP - could not find local character for the actor", activity)
  # end

  defp handle_activity_with(module, _actor, _activity, _object) do
    debug(module, "AP - no match in handle_activity_with")
    # error(activity, "AP - no module defined to handle_activity_with activity")
    # error(object, "AP - no module defined to handle_activity_with object")
    {:no_federation_module_match, :ignore}
  end

  defp activity_character(%{"actor" => actor}) do
    activity_character(actor)
  end

  defp activity_character(%{data: %{} = data}) do
    activity_character(data)
  end

  defp activity_character(%{"id" => actor}) when is_binary(actor) do
    activity_character(actor)
  end

  defp activity_character(actor) when is_binary(actor) do
    info(actor, "AP - receive - get activity_character")
    # FIXME to handle actor types other than Person/User
    with {:error, e} <-
           AdapterUtils.get_or_fetch_and_create_by_uri(actor, fetch_collection: false) |> info do
      error(e, "AP - could not find local character for the actor")
      {:ok, AdapterUtils.get_or_create_service_character()}
    end
  end

  defp activity_character(%{"object" => object}) do
    activity_character(object)
  end

  defp activity_character(%{"attributedTo" => actor}) do
    activity_character(actor)
  end

  defp activity_character(%{actor: actor}) do
    activity_character(actor)
  end

  defp activity_character(actor) do
    error(actor, "AP - could not find an actor in the activity or object")
    {:ok, AdapterUtils.get_or_create_service_character()}
  end

  def no_federation_module_match(error, attrs \\ nil) do
    error(
      attrs,
      "ActivityPub - Unable to process incoming federated activity - #{error}"
    )

    {:no_federation_module_match, {error, attrs}}
  end
end
