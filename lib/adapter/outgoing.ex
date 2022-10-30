# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Outgoing do
  import Untangle
  import Bonfire.Federate.ActivityPub
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Common.Utils

  # defines default types that can be federated as AP Actors (overriden by config)
  @types_characters Application.compile_env(
                      :bonfire,
                      :types_character_schemas,
                      [
                        Bonfire.Data.Identity.User,
                        # CommonsPub.Communities.Community,
                        # CommonsPub.Collections.Collection,
                        Bonfire.Data.Identity.Character
                      ]
                    )

  def maybe_federate(subject \\ nil, verb, thing) do
    verb = verb || :create

    thing_local? = AdapterUtils.is_local?(thing)
    subject_local? = AdapterUtils.is_local?(subject)

    if (is_nil(subject) and thing_local?) or subject_local? do
      prepare_and_queue(subject, verb, thing)
    else
      info(
        thing,
        "Skip (re)federating out '#{verb}' activity by remote actor '#{Utils.ulid(subject)}'=#{subject_local?}, or remote object '#{Utils.ulid(thing)}'=#{thing_local?}"
      )

      :ignored
    end
  end

  defp prepare_and_queue(subject \\ nil, verb, thing)

  defp prepare_and_queue(_subject, :update, %{__struct__: type, id: id})
       when type in @types_characters do
    # Works for Users, Collections, Communities (not MN.ActivityPub.Actor)
    with {:ok, actor} <- ActivityPub.Actor.get_cached(pointer: id),
         actor_object <-
           ActivityPubWeb.ActorView.render("actor.json", %{actor: actor}),
         params <- %{
           to: [AdapterUtils.public_uri()],
           cc: [actor.data["followers"]],
           object: actor_object,
           actor: actor,
           local: true
         } do
      ActivityPub.Actor.set_cache(actor)
      ActivityPub.update(params)
    else
      e ->
        preparation_error("Error while attempting to federate the update", e)
    end
  end

  defp prepare_and_queue(_subject, :delete, %Bonfire.Data.Identity.User{} = user) do
    # is this broken?
    with actor <- AdapterUtils.character_to_actor(user) do
      ActivityPub.Actor.set_cache(actor)
      ActivityPub.delete(actor)
    end
  end

  defp prepare_and_queue(_subject, :delete, %{__struct__: type} = character)
       when type in @types_characters do
    # Works for Collections, Communities (not User or MN.ActivityPub.Actor)

    with {:ok, creator} <-
           ActivityPub.Actor.get_cached(pointer: character.creator_id),
         actor <- AdapterUtils.character_to_actor(character) do
      ActivityPub.Actor.invalidate_cache(actor)
      ActivityPub.delete(actor, true, creator.ap_id)
    end
  end

  # delete anything else
  defp prepare_and_queue(_subject, :delete, %{__struct__: type} = thing) do
    with %{} = object <-
           ActivityPub.Object.get_cached!(pointer: thing.id) do
      ActivityPub.delete(object)
    else
      e -> preparation_error("Error while attempting to federate the delete", e)
    end
  end

  defp prepare_and_queue(subject, verb, %{__struct__: object_type} = local_object) do
    case Bonfire.Federate.ActivityPub.FederationModules.federation_module({verb, object_type}) do
      {:ok, module} when is_atom(module) ->
        info(
          module,
          "Federate.ActivityPub - delegating to module to handle verb '#{verb}' for object type #{object_type}"
        )

        cond do
          Code.ensure_loaded?(module) and function_exported?(module, :ap_publish_activity, 2) ->
            Bonfire.Common.Utils.maybe_apply(
              module,
              :ap_publish_activity,
              [verb, local_object],
              &preparation_error/2
            )

          true ->
            Bonfire.Common.Utils.maybe_apply(
              module,
              :ap_publish_activity,
              [subject, verb, local_object],
              &preparation_error/2
            )
        end
        |> case do
          {:ok, activity} ->
            {:ok, activity}

          {:ok, activity, object} ->
            {:ok, activity, object}

          :ignore ->
            :ignore

          e ->
            warn(e, "Unexpected result from federation preparation function")
            e
        end

      _ ->
        # TODO: fallback to creating a Note for unknown types that have a PostContent, Profile or Named?

        preparation_error(
          "No FederationModules was defined for verb {#{inspect(verb)}, #{object_type}}",
          [verb, local_object]
        )
    end
  end

  defp prepare_and_queue(_subject, verb, object) do
    preparation_error("Unrecognised object for AP publisher", [verb, object])
  end

  def preparation_error(error, [_subject, verb, %{__struct__: object_type, id: id} = object]) do
    error(
      object,
      "Federate.ActivityPub - Unable to federate out - #{error}... object ID: #{id} - with verb: #{verb} ; object type: #{object_type}"
    )

    :ignored
  end

  def preparation_error(error, [_subject, verb, object]) do
    error(
      object,
      "Federate.ActivityPub - Unable to federate out - #{error} - with verb: #{verb}}"
    )

    :ignored
  end

  def preparation_error(error, object) do
    error(object, "Federate.ActivityPub - Unable to federate out - #{error}...")

    :ignored
  end

  def push_now!(activity) do
    activity = ap_activity!(activity)

    # ActivityPubWeb.Federator.perform(:publish, ap_activity!(activity))

    case Oban.Testing.perform_job(
           ActivityPub.Workers.PublisherWorker,
           %{"op" => "publish", "activity_id" => Utils.id(activity), "repo" => repo()},
           repo: repo()
         ) do
      :ok -> {:ok, activity}
    end

    # NOTE: the above is not needed IF running Oban in :inline testing mode
    # case activity do
    #   %{__struct__: ActivityPub.Object} = object -> {:ok, object}
    #   %{__struct__: ActivityPub.Actor} = actor -> {:ok, actor}
    # end
  end

  def ap_activity!(%{activity: %{federate_activity_pub: activity}}) do
    ap_activity!(activity)
  end

  def ap_activity!(%{federate_activity_pub: activity}) do
    ap_activity!(activity)
  end

  def ap_activity!(%{data: _} = activity) do
    activity
  end

  def ap_activity!({:ok, activity}) do
    ap_activity!(activity)
  end

  def ap_activity!({:ok, activity, _object}) do
    ap_activity!(activity)
  end
end