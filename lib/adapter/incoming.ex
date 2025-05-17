defmodule Bonfire.Federate.ActivityPub.Incoming do
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  require ActivityPub.Config
  import Bonfire.Federate.ActivityPub
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  # import AdapterUtils, only: [log: 1]
  # alias Bonfire.Federate.ActivityPub.Adapter
  # alias Bonfire.Data.ActivityPub.Peered

  # the following constants are derived from config, so please make any changes/additions there

  @creation_verbs ["Create"]

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

    case fetch_final_object(target_id,
           return_tombstones: e(activity.data, "type", nil) == "Delete"
         ) do
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
    is_deleted? =
      e(activity.data, "type", nil) in ["Delete", "Tombstone"]

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
      when ActivityPub.Config.is_in(object_type, :supported_actor_types) do
    info("AP Match#0 - update actor")

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

    with {:ok, subject} <- activity_character(activity) |> info("activity_character"),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(
               {activity_type, object_type}
             )
             |> info("AP attempt #1.1 - with activity_type and object_type"),
             subject,
             activity,
             object
           ),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type)
             |> info("AP attempt #1.2 - with activity_type"),
             subject,
             activity,
             object
           ),
         {:no_federation_module_match, _} <-
           handle_activity_with(
             Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type)
             |> info("AP attempt #1.3 - with object_type"),
             subject,
             activity,
             object
           ) do
      receive_activity_fallback(activity, object, subject)
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

    with {:ok, subject} <- activity_character(activity),
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

    with {:ok, subject} <- activity_character(activity),
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

  defp fetch_final_object(object_id, opts) do
    case ActivityPub.Federator.Fetcher.get_cached_object_or_fetch_ap_id(object_id, opts) do
      # support receiving an activity when we're expecting an object (eg for a flag or a like)
      {:ok, %{data: %{"type" => "Create", "object" => actual_object_id}}}
      when is_binary(actual_object_id) and actual_object_id != object_id ->
        fetch_final_object(actual_object_id, opts)

      {:ok, object} ->
        {:ok, object}

      other ->
        error(other)
    end
  end

  defp receive_activity_fallback(activity, object, subject \\ nil) do
    module = Application.get_env(:bonfire, :federation_fallback_module)

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

    if ap_obj_id && Bonfire.Common.Needles.exists?(ap_obj_id) do
      error(ap_obj_id, "Already exists locally")
      Bonfire.Common.Needles.get(ap_obj_id, skip_boundary_check: true)
    else
      pointer_id =
        with published when is_binary(published) <-
               object.data["published"] || activity.data["published"] do
          DatesTimes.generate_ulid_if_past(published)
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
          ap_obj_id,
          type: :object
        )

        # object = ActivityPub.Object.normalize(object)
        old_pointer_id = e(object, :pointer_id, nil)
        object_id = id(object)
        # FIXME
        if object_id &&
             (is_nil(old_pointer_id) or
                old_pointer_id != pointable_object_id),
           do:
             ActivityPub.Object.update_existing(object_id, %{
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

    with {:ok, %struct{id: pointable_object_id} = pointable_object} <-
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

      id =
        if struct not in [ActivityPub.Object, ActivityPub.Actor],
          do:
            Types.uid(pointable_object_id)
            |> debug("uiid")

      if id && e(activity, :data, "type", nil) not in ["Update", "Delete"] do
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
    warn(module, "AP - no match in handle_activity_with")
    # error(activity, "AP - no module defined to handle_activity_with activity")
    # error(object, "AP - no module defined to handle_activity_with object")
    {:no_federation_module_match, :ignore}
  end

  defp activity_character(%{data: %{"type" => type, "actor" => actor}})
       when type in ["Delete", "Tombstone"] do
    AdapterUtils.get_character(actor, skip_boundary_check: true)
  end

  defp activity_character(%{data: %{"type" => "Tombstone"}} = actor) do
    AdapterUtils.get_character(actor, skip_boundary_check: true)
  end

  defp activity_character(%{data: %{} = data}) do
    activity_character(data)
  end

  defp activity_character(%{"actor" => actor}) do
    activity_character(actor)
  end

  defp activity_character(%{"id" => actor}) when is_binary(actor) do
    activity_character(actor)
  end

  defp activity_character(actor) when is_binary(actor) do
    info(actor, "AP - receive - get activity_character")
    # FIXME to handle actor types other than Person/User
    with {:error, e} <-
           AdapterUtils.get_or_fetch_and_create_by_uri(actor,
             fetch_collection: false,
             return_tombstones: true
           )
           |> debug("fetched actor") do
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
