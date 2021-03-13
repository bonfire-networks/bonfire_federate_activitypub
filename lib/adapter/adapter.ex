# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Adapter do
  @moduledoc """
  Adapter functions delegated from the `ActivityPub` Library
  """
  # alias Bonfire.Federate.ActivityPub.Utils
  alias Bonfire.Federate.ActivityPub.APReceiverWorker
  require Logger

  @behaviour ActivityPub.Adapter

  def base_url() do
    Bonfire.Common.URIs.base_url()
  end

  @doc """
  Queue-up incoming activities to be processed by `Bonfire.Federate.ActivityPub.APReceiverWorker`
  """
  def handle_activity(activity) do
    APReceiverWorker.enqueue("handle_activity", %{
      "activity_id" => activity.id,
      "activity" => activity.data
    })
  end

  def get_follower_local_ids(actor) do
    {:ok, actor} = Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_id(actor.pointer_id)
    {:ok, follows} = Bonfire.Social.Follows.many(context: actor.id)

    follows |> Enum.map(fn follow -> follow.creator_id end)
  end

  def get_following_local_ids(actor) do
    {:ok, actor} = Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_id(actor.pointer_id)
    {:ok, follows} = Bonfire.Social.Follows.many(creator: actor.id)

    follows |> Enum.map(fn follow -> follow.context_id end)
  end

  def get_actor_by_id(id) do
    case Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_id(id) do
      {:ok, character} ->
        # IO.inspect(get_raw_character_by_id: actor)
        {:ok, Bonfire.Federate.ActivityPub.Types.character_to_actor(character)}

      _ ->
        {:error, "not found"}
    end
  end

  def get_actor_by_username(username) do
    # TODO: Make more generic (currently assumes the actor is person)
    module = Bonfire.Common.Config.get!(Bonfire.Federate.ActivityPub.Adapter)[:actor_modules]["Person"]
    apply(module, :get_actor_by_username, [username])
  end

  def get_actor_by_ap_id(ap_id) do
    case Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_ap_id(ap_id) do
      {:ok, character} ->
        {:ok, Bonfire.Federate.ActivityPub.Types.character_to_actor(character)}

      _ ->
        {:error, "not found"}
    end
  end

  # def redirect_to_object(id) do
  #   if System.get_env("LIVEVIEW_ENABLED", "true") == "true" do
  #     url = Bonfire.Common.Utils.object_url(id)
  #     if !String.contains?(url, "/404"), do: url
  #   end
  # end

  def redirect_to_actor(username) do
    if System.get_env("LIVEVIEW_ENABLED", "true") == "true" do
      case Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_username(username) do
        {:ok, character} ->
          url = Bonfire.Common.Utils.object_url(character)
          if !String.contains?(url, "/404"), do: url

        _ ->
          nil
      end
    end
  end

  def update_local_actor(actor, params) do
    module = Bonfire.Common.Config.get!(Bonfire.Federate.ActivityPub.Adapter)[:actor_modules]["Person"]
    apply(module, :update_local_actor, [actor, params])
  end

  def update_remote_actor(actor_object) do
    data = actor_object.data

    with {:ok, character} <-
           Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_id(actor_object.pointer_id),
         creator <- Bonfire.Repo.maybe_preload(character, :creator) |> Map.get(:creator, nil) do
      # FIXME - support other types
      params = %{
        name: data["name"],
        summary: data["summary"],
        icon_id:
          Bonfire.Federate.ActivityPub.Utils.maybe_create_icon_object(
            Bonfire.Federate.ActivityPub.Utils.maybe_fix_image_object(data["icon"]),
            creator
          ),
        image_id:
          Bonfire.Federate.ActivityPub.Utils.maybe_create_image_object(
            Bonfire.Federate.ActivityPub.Utils.maybe_fix_image_object(data["image"]),
            creator
          )
      }

      # FIXME
      case character do
        # %Bonfire.Data.Identity.User{} ->
        #   Bonfire.Me.Users.ap_receive_update(character, params, creator)

        # %CommonsPub.Communities.Community{} ->
        #   CommonsPub.Communities.ap_receive_update(character, params, creator)

        # %CommonsPub.Collections.Collection{} ->
        #   CommonsPub.Collections.ap_receive_update(character, params, creator)

        true ->
          Bonfire.Me.Characters.ap_receive_update(character, params, creator)
      end
    end
  end

  def maybe_create_remote_actor(actor) do
    module = Bonfire.Common.Config.get!(Bonfire.Federate.ActivityPub.Adapter)[:actor_modules]["Person"]
    apply(module, :maybe_create_remote_actor, [actor])
  end
end
