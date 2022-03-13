defmodule Bonfire.Federate.ActivityPub.Receiver do
  import Where
  use Arrows
  import Bonfire.Federate.ActivityPub.Utils, only: [log: 1]
  alias Bonfire.Search.Indexer
  alias Bonfire.Common.Utils
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Data.ActivityPub.Peered

  # the following constants are derived from config, so please make any changes/additions there

  @creation_verbs ["Create"]
  @actor_types Bonfire.Common.Config.get([Bonfire.Federate.ActivityPub.Adapter, :actor_types], ["Person", "Group", "Application", "Service", "Organization"])

  def receive_activity(activity_id) when is_binary(activity_id) do
    log("AP - load the activity data")
    ActivityPub.Object.get_by_id(activity_id)
    |> receive_activity()
  end

  def receive_activity(activity) when not is_map_key(activity, :data) do
    log("AP - case when the worker gives us an activity")
    receive_activity(%{data: activity})
  end

  def receive_activity(
        %{
          data: %{
            "object" => object_id
          }
        } = activity
      ) when is_binary(object_id) do
    log("AP - load the object data")
    object = Bonfire.Federate.ActivityPub.Utils.get_object_or_actor_by_ap_id!(object_id)

    #IO.inspect(activity: activity)
    #IO.inspect(object: object)

    receive_activity(activity, object)
  end

  def receive_activity(
        %{
          data: %{
            "object" => object
          }
        } = activity
      ) do
    log("AP - case #1 when the object comes to us embeded in the activity")

    #IO.inspect(activity: activity)
    #IO.inspect(object: object)

    receive_activity(activity, object)
  end

  def receive_activity(activity, object) when not is_map_key(object, :data) do
    log("AP - case #2 when the object comes to us embeded in the activity")
    receive_activity(activity, %{data: object})
  end

  # Activity: Update + Object: actor/character
  def receive_activity(
        %{data: %{"type" => "Update"}} = _activity,
        %{data: %{"type" => object_type, "id" => ap_id}} = _object
      )
      when object_type in @actor_types do
    log("AP Match#0 - update actor")

    with {:ok, actor} <- ActivityPub.Actor.get_cached_by_ap_id(ap_id),
         {:ok, actor} <- Bonfire.Federate.ActivityPub.Adapter.update_remote_actor(actor) do
      # Indexer.maybe_index_object(actor)
      :ok
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

    log(
      "AP Match#1 - with activity_type and object_type: #{activity_type} & #{object_type}"
    )

    with {:ok, actor} <- activity_character(activity),
        {:error, _} <-
            handle_activity_with(
              Bonfire.Federate.ActivityPub.FederationModules.federation_module({activity_type, object_type}),
              actor,
              activity,
              object
            ),
        {:error, _} <-
            handle_activity_with(
              Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type),
              actor,
              activity,
              object
            ),
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

  def receive_activity(
      %{
        data: %{
          "type" => activity_type
        }
      } = activity,
      object
    )
    when is_binary(activity_type) do
      log(
        "AP Match#2 - by activity_type only: #{activity_type}"
      )

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
    log(
      "AP Match#3 - by object_type only: #{object_type}"
    )

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
    log(
      "AP Match#4 - receive_activity_fallback"
    )

    receive_activity_fallback(activity, object)
  end

  defp receive_activity_fallback(activity, object, actor \\ nil) do
    if Application.get_env(:bonfire, :federation_fallback_module) do
      log("AP - handling activity with fallback")
      module = Application.get_env(:bonfire, :federation_fallback_module)
      module.create(activity, object, actor)
    else
      error = "ActivityPub - ignored incoming activity - unhandled activity or object type"
      receive_error("#{error}")
      log("AP activity: #{inspect(activity, pretty: true)}")
      log("AP object: #{inspect(object, pretty: true)}")
      {:error, error}
    end
  end

  @doc """
  Create an object without an activity
  """
  def receive_object(creator, object) do
    log("AP - Create an object without an activity")
    receive_activity(%{data: %{"type" => "Create", "actor" => creator}}, object)
  end

  # for creation activities we need to take into account the date, and save canonical url/update pointer
  # This should not be done if the object is local, i. e. local actor as the object of a follow
  defp handle_activity_with({:ok, module}, character, %{data: %{"type" => verb}} = activity, object)
    when is_atom(module) and not is_nil(module) and verb in @creation_verbs do

    ap_obj_id = object.data["id"]
    pointer_id =
      with published when is_binary(published) <- object.data["published"] || activity.data["published"],
      {:ok, utc_date_published, _} <- DateTime.from_iso8601(published) |> dump("date from AP"),
      :lt <- DateTime.compare(utc_date_published, DateTime.now!("Etc/UTC")) do # only if published in the past
        utc_date_published
        |> dump()
        |> DateTime.to_unix()
        |> dump()
        |> Pointers.ULID.generate()
      else _ -> nil
    end

    Utils.date_from_pointer(pointer_id) |> dump("date from pointer")

    log("AP - handle_activity_with: #{module} to Create #{ap_obj_id} as #{inspect pointer_id}")
    # dump(object)

    with {:ok, %{id: pointable_object_id} = pointable_object} <- Utils.maybe_apply(
        module,
        :ap_receive_activity,
        [character, activity, %{object | pointer_id: pointer_id}],
        &receive_error/2
      ),
      {:ok, %Peered{}} <- Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(pointable_object_id, ap_obj_id) do

      log("AP - created remote object as local pointable #{pointable_object_id} for #{ap_obj_id}")
      # IO.inspect(pointable_object)

      object = ActivityPub.Object.normalize(object)

      if object && (is_nil(object.pointer_id) or object.pointer_id !=pointable_object_id), do: ActivityPub.Object.update(object, %{pointer_id: pointable_object_id})

      {:ok, pointable_object}
    else
      e ->
        error(e)
        throw {:error, "AP - could not create activity for #{ap_obj_id}"}
    end
  end

  defp handle_activity_with({:ok, module}, character, activity, object)
    when is_atom(module) and not is_nil(module) do
    log("AP - handle_activity_with: #{module}")

    with {:ok, %{id: pointable_object_id} = pointable_object} <- Utils.maybe_apply(
      module,
      :ap_receive_activity,
      [character, activity, object],
      &receive_error/2
    ) do

      activity = ActivityPub.Object.normalize(activity)
      ActivityPub.Object.update(activity |> dump, %{pointer_id: pointable_object_id})

      {:ok, pointable_object}
    end
  end

  # defp handle_activity_with(_module, {:error, _}, activity, _) do
  #   receive_error("AP - could not find local character for the actor", activity)
  # end

  defp handle_activity_with(_module, _actor, _activity, _object) do
    log("AP - no module defined to handle_activity_with")
    {:error, :skip}
  end

  def activity_character(%{"actor" => %{"id" => actor}}) do
    activity_character(actor)
  end

  def activity_character(%{"actor" => actor}) do
    activity_character(actor)
  end

  def activity_character(%{data: data}) do
    activity_character(data)
  end

  def activity_character(actor) when is_binary(actor) do
    log("AP - activity_character for #{actor}")
    # FIXME to handle actor types other than Person/User
    with {:error, :not_found} <- Adapter.character_module("Person").by_ap_id(actor) do
      receive_error("AP - could not find local character for the actor", actor)
    end
  end

  def activity_character(actor), do: {:ok, nil}


  def receive_error(error, attrs \\ nil) do
    error(attrs, "ActivityPub - Unable to process incoming federated activity - #{error}")

    {:error, {error, attrs}}
  end
end
