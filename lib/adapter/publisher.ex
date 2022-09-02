# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Publisher do
  import Untangle
  alias Bonfire.Federate.ActivityPub.Utils

  # TODO: move specialised publish funcs to context modules (or make them extensible for extra types)

  # defines default types that can be federated as AP Actors (overriden by config)
  @types_characters Application.compile_env(:bonfire, :types_character_schemas, [
                      Bonfire.Data.Identity.User,
                      # CommonsPub.Communities.Community,
                      # CommonsPub.Collections.Collection,
                      Bonfire.Data.Identity.Character
                    ])


  def publish("update", %{__struct__: type, id: id})
      when type in @types_characters do
    # Works for Users, Collections, Communities (not MN.ActivityPub.Actor)
    with {:ok, actor} <- ActivityPub.Actor.get_by_local_id(id),
         actor_object <- ActivityPubWeb.ActorView.render("actor.json", %{actor: actor}),
         params <- %{
           to: [Utils.public_uri()],
           cc: [actor.data["followers"]],
           object: actor_object,
           actor: actor,
           local: true
         } do
      ActivityPub.Actor.set_cache(actor)
      ActivityPub.update(params)
    else
      e ->
        publish_error("Error while attempting to publish", e)

        {:error, e}
    end
  end

  def publish("delete", %Bonfire.Data.Identity.User{} = user) do
    # is this broken?
    with actor <- Utils.character_to_actor(user) do
      ActivityPub.Actor.set_cache(actor)
      ActivityPub.delete(actor)
    end
  end

  def publish("delete", %{__struct__: type} = character) when type in @types_characters do
    # Works for Collections, Communities (not User or MN.ActivityPub.Actor)

    with {:ok, creator} <- ActivityPub.Actor.get_by_local_id(character.creator_id),
         actor <- Utils.character_to_actor(character) do
      ActivityPub.Actor.invalidate_cache(actor)
      ActivityPub.delete(actor, true, creator.ap_id)
    end
  end

  def publish("delete", %{__struct__: type} = thing) do # delete anything else
    with %ActivityPub.Object{} = object <- ActivityPub.Object.get_cached_by_pointer_id(thing.id) do
      ActivityPub.delete(object)
    else
      e -> {:error, e}
    end
  end

  def publish(verb, %{__struct__: object_type} = local_object) do
    case Bonfire.Federate.ActivityPub.FederationModules.federation_module({verb, object_type}) do
    {:ok, module} when is_atom(module) ->
      info(module, "Federate.ActivityPub - delegating to module to handle verb '#{verb}' for object type #{object_type}")
      Bonfire.Common.Utils.maybe_apply(module, :ap_publish_activity, [verb, local_object], &publish_error/2)
    _ ->
      publish_error("No FederationModules was defined for verb {#{inspect verb}, #{object_type}}", [verb, local_object])
    end
  end

  def publish(verb, object) do
    publish_error("Unrecognised object for AP publisher", [verb, object])
  end

  def publish_error(error, [verb, %{__struct__: object_type, id: id} = object]) do
    error(
      object,
      "Federate.ActivityPub - Unable to federate out - #{error}... object ID: #{id} - with verb: #{verb} ; object type: #{object_type}"
    )

    :ignored
  end

  def publish_error(error, [verb, object]) do
    error(object, "Federate.ActivityPub - Unable to federate out - #{error} - with verb: #{verb}}")

    :ignored
  end

  def publish_error(error, object) do
    error(object, "Federate.ActivityPub - Unable to federate out - #{error}...")

    :ignored
  end
end
