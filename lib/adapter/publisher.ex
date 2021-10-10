# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Publisher do
  require Logger
  alias Bonfire.Federate.ActivityPub.Utils

  # TODO: move specialised publish funcs to context modules (or make them extensible for extra types)

  # defines default types that can be federated as AP Actors (overriden by config)
  @types_characters Bonfire.Common.Config.get([Bonfire.Instance, :types_characters], [
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
      e -> {:error, e}
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
    Bonfire.Common.ContextModules.maybe_apply(object_type, :ap_publish_activity, [verb, local_object], &error/2)
  end


  def publish(verb, object) do
    error("Unrecognised object for AP publisher", [verb, object])

    :ignored
  end

  def error(error, [verb, %{__struct__: object_type, id: id} = object]) do
    Logger.error(
      "ActivityPub - Unable to federate out - #{error}... object ID: #{id} ; verb: #{verb} ; object type: #{object_type}"
    )
    IO.inspect(object: object)

    :ignored
  end

  def error(error, [verb, object]) do
    Logger.error("ActivityPub - Unable to federate out - #{error}... verb: #{verb}}")

    IO.inspect(object: object)

    :ignored
  end
end
