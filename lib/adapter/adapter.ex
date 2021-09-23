# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Adapter do
  @moduledoc """
  Adapter functions delegated from the `ActivityPub` Library
  """
  # alias Bonfire.Federate.ActivityPub.Utils
  alias Bonfire.Federate.ActivityPub.APReceiverWorker
  alias Bonfire.Common.Utils
  import Utils, only: [maybe_apply: 3]
  alias Bonfire.Common.URIs
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
    character_module("Person")
    |> maybe_apply(:get_follower_local_ids, [actor])
  end

  def get_following_local_ids(actor) do
    character_module("Person")
    |> maybe_apply(:get_following_local_ids, [actor])
  end

  def get_actor_by_id(id) do
    character_module("Person")
    |> maybe_apply(:get_actor_by_id, [id])
  end

  def get_actor_by_username(username) do
    # TODO: Make more generic (currently assumes the actor is person)
    character_module("Person")
    |> maybe_apply(:get_actor_by_username, [username])
  end

  def get_actor_by_ap_id(ap_id) do
    character_module("Person")
    |> maybe_apply(:get_actor_by_ap_id, [ap_id])
  end

  # def redirect_to_object(id) do
  #   if System.get_env("LIVEVIEW_ENABLED", "true") == "true" do
  #     url = Bonfire.Common.Utils.object_url(id)
  #     if !String.contains?(url, "/404"), do: url
  #   end
  # end

  def redirect_to_actor(username) do
    if System.get_env("LIVEVIEW_ENABLED", "true") == "true" do
      case Bonfire.Federate.ActivityPub.Utils.get_character_by_username(username) do
        {:ok, character} ->
          url = Bonfire.Me.Characters.character_url(character)
          if !String.contains?(url, "/404"), do: url

        _ ->
          nil
      end
    end
  end

  def update_local_actor(actor, params) do
    character_module("Person")
    |> maybe_apply(:update_local_actor, [actor, params])
  end

  # TODO: refactor & move to Me context(s)?
  def update_remote_actor(actor_object) do
    data = actor_object.data

    with {:ok, character} <-
           Bonfire.Federate.ActivityPub.Utils.get_character_by_id(actor_object.pointer_id),
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
        %Bonfire.Data.Identity.User{} ->
          Bonfire.Me.Users.ActivityPub.update(character, params)

        # %CommonsPub.Communities.Community{} ->
        #   CommonsPub.Communities.ap_receive_update(character, params, creator)

        # %CommonsPub.Collections.Collection{} ->
        #   CommonsPub.Collections.ap_receive_update(character, params, creator)

        true ->
          Bonfire.Me.Characters.ap_receive_update(character, params, creator) # TODO fallback
      end
    end
  end

  def maybe_create_remote_actor(actor) do
    character_module("Person")
    |> maybe_apply(:maybe_create_remote_actor, [actor])
  end

  def get_redirect_url(username_or_id) do
    if Utils.is_ulid?(username_or_id) do
      get_object_url(username_or_id)
    else
      get_actor_url(username_or_id)
    end
  end

  def get_object_url(id) do
    URIs.path(id)
  end

  def get_actor_url(username) do
    #FIXME: naughty
    module = character_module("Person")
    case module.by_username(username) do
      {:ok, user} -> URIs.path(user)
      {:error, _} -> "/404"
    end
  end

  def character_module(type) do
    with {:ok, module} <- Bonfire.Federate.ActivityPub.FederationModules.federation_module(type) do
      module
    else _ ->
      Bonfire.Me.Users.ActivityPub # fallback
    end
  end

end
