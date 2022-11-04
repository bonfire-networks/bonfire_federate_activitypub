# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Adapter do
  @moduledoc """
  Adapter functions delegated from the `ActivityPub` Library
  """

  alias Bonfire.Federate.ActivityPub.AdapterUtils
  import AdapterUtils, only: [log: 1]

  use Bonfire.Common.Utils

  alias Bonfire.Common.Pointers
  alias Bonfire.Common.URIs
  alias Bonfire.Me.Characters
  alias Bonfire.Federate.ActivityPub.Incoming

  import Bonfire.Federate.ActivityPub
  import Untangle

  @behaviour ActivityPub.Adapter

  def base_url() do
    Bonfire.Common.URIs.base_url()
  end

  @doc """
  Process incoming activities
  """
  def handle_activity(activity) do
    # Incoming.Worker.enqueue("handle_activity", %{
    #   "activity_id" => activity.id
    #   # "activity" => activity
    # })
    Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
    |> info()
  end

  def get_follower_local_ids(actor) do
    # info(actor)
    with {:ok, character} <- Characters.by_username(actor.username) do
      # info(character)
      Bonfire.Social.Follows.all_subjects_by_object(character)
      # |> info()
      |> Enum.map(& &1.id)
    end
  end

  def get_following_local_ids(actor) do
    with {:ok, character} <- Characters.by_username(actor.username) do
      Bonfire.Social.Follows.all_objects_by_subject(character)
      |> Enum.map(& &1.id)
    end
  end

  def get_actor_by_id(id) do
    with {:ok, character} <- AdapterUtils.get_character_by_id(id) |> info(),
         true <- AdapterUtils.is_local?(character),
         %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
      {:ok, actor}
    end
  end

  def get_actor_by_username(username) do
    with {:ok, character} <- AdapterUtils.get_character_by_username(username),
         %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
      {:ok, actor}
    end
  end

  def get_actor_by_ap_id(ap_id) do
    # TODO: Make more generic (currently assumes the actor is user)
    with {:ok, character} <- AdapterUtils.get_local_character_by_ap_id(ap_id),
         %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
      {:ok, actor}
    end
  end

  # def redirect_to_object(id) do
  #   if System.get_env("LIVEVIEW_ENABLED", "true") == "true" do
  #     url = object_url(id)
  #     if !String.contains?(url, "/404"), do: url
  #   end
  # end

  def redirect_to_actor(username) do
    if System.get_env("LIVEVIEW_ENABLED", "true") == "true" do
      case AdapterUtils.get_character_by_username(username) do
        {:ok, character} ->
          url = Bonfire.Me.Characters.character_url(character)
          if !String.contains?(url, "/404"), do: url

        _ ->
          nil
      end
    end
  end

  def update_local_actor(actor, params) do
    with {:ok, character} <- AdapterUtils.get_character_by_ap_id(actor) do
      keys = e(params, :keys, nil)

      params = Map.put(params, :character, %{id: character.id, actor: %{signing_key: keys}})

      # debug("update_local_actor: #{inspect character} with #{inspect params}")
      # FIXME use federation_module?
      Bonfire.Common.ContextModule.maybe_apply(
        character,
        :update_local_actor,
        [character, params]
      )
    end
  end

  # TODO: refactor & move to Me context(s)?

  def update_remote_actor(%{pointer_id: pointer_id} = actor) when is_binary(pointer_id) do
    AdapterUtils.get_character_by_id(pointer_id)
    |> info()
    ~> update_remote_actor(actor)
  end

  def update_remote_actor(actor) do
    AdapterUtils.get_character_by_ap_id(actor)
    |> info()
    |> update_remote_actor(actor)
  end

  def update_remote_actor(%{} = character, %{data: data}),
    do: update_remote_actor(character, data)

  def update_remote_actor(%{} = character, data) do
    params =
      %{
        name: data["name"],
        summary: data["summary"],
        icon_id:
          AdapterUtils.maybe_create_icon_object(
            AdapterUtils.maybe_fix_image_object(data["icon"]),
            character
          ),
        image_id:
          AdapterUtils.maybe_create_image_object(
            AdapterUtils.maybe_fix_image_object(data["image"]),
            character
          )
      }
      |> info()

    # TODO - support other types
    Bonfire.Me.Users.update_remote(character, params)
  end

  def update_remote_actor({:ok, character}, actor) do
    update_remote_actor(character, actor)
  end

  def update_remote_actor(other, actor) do
    info(other, "could not find the character to update, gonna try to create instead")
    maybe_create_remote_actor(actor)
  end

  @doc """
  For updating an Actor in cache after a User/etc is updated
  """
  def update_local_actor_cache(character) do
    with %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
      ActivityPub.Actor.set_cache(actor)
    end

    {:ok, character}
  end

  def maybe_create_remote_actor(actor) when not is_nil(actor) do
    log("AP - maybe_create_remote_actor for #{e(actor, :ap_id, nil) || e(actor, "id", nil)}")

    case AdapterUtils.get_character_by_ap_id(actor) do
      {:ok, character} ->
        log("AP - remote actor already exists, return it: #{ulid(character)}")
        # already exists
        {:ok, character}

      e ->
        warn(e, "seems like a new character? create it...")
        AdapterUtils.create_remote_actor(actor)

        # |> debug
    end
  end

  def get_redirect_url(id_or_username_or_object)

  def get_redirect_url(id_or_username) when is_binary(id_or_username) do
    # IO.inspect(get_redirect_url: id_or_username)
    if is_ulid?(id_or_username) do
      get_object_url(id_or_username)
    else
      get_url_by_username(id_or_username)
    end
  end

  def get_redirect_url(%{username: username}) when is_binary(username),
    do: get_redirect_url(username) |> debug()

  def get_redirect_url(%{pointer_id: id}) when is_binary(id),
    do: get_redirect_url(id) |> debug()

  def get_redirect_url(%{data: %{"id" => id}}) when is_binary(id),
    do: get_redirect_url(id) |> debug()

  def get_redirect_url(%{} = object), do: URIs.path(object) |> debug()

  def get_redirect_url(other) do
    error(other, "Param not recognised")
    nil
  end

  def get_object_url(id), do: URIs.path(id)

  defp get_url_by_username(username) do
    case URIs.path(username) do
      path when is_binary(path) ->
        path

      _ ->
        case AdapterUtils.get_character_by_username(username) do
          {:ok, user_etc} -> URIs.path(user_etc)
          {:error, _} -> "/404"
        end
    end
  end

  def maybe_publish_object(pointer_id) when is_binary(pointer_id) do
    Bonfire.Common.Pointers.get(pointer_id)
    ~> maybe_publish_object()
  end

  def maybe_publish_object(%{} = object) do
    object
    # |> info()
    |> Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(:create, ...)
  end
end
