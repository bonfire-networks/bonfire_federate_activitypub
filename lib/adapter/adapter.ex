# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Adapter do
  @moduledoc """
  Adapter functions delegated from the `ActivityPub` Library
  """

  alias Bonfire.Federate.ActivityPub.Utils, as: APUtils
  import APUtils, only: [log: 1]

  use Bonfire.Common.Utils

  alias Bonfire.Common.Pointers
  alias Bonfire.Common.URIs
  alias Bonfire.Me.Characters
  alias Bonfire.Federate.ActivityPub.APReceiverWorker

  import Bonfire.Federate.ActivityPub
  import Where

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
    # dump(actor)
    with {:ok, character} <- Characters.by_username(actor.username) do
    # dump(character)
      Bonfire.Social.Follows.all_subjects_by_object(character)
      # |> dump()
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
    # character_module("Person") # FIXME
    # |> maybe_apply(:get_actor_by_id, [id])

    with {:ok, character} <- APUtils.get_character_by_id(id),
    %ActivityPub.Actor{} = actor <- Bonfire.Common.ContextModules.maybe_apply(character, :format_actor, character) do
      {:ok, actor} # TODO: use federation_module instead of context_module?
    end
  end

  def get_actor_by_username(username) do
    # TODO: Make more generic (currently assumes the actor is person)
    # character_module("Person")
    # |> maybe_apply(:get_actor_by_username, [username])

    with {:ok, character} <- APUtils.get_character_by_username(username),
    %ActivityPub.Actor{} = actor <- Bonfire.Common.ContextModules.maybe_apply(character, :format_actor, character) do
      {:ok, actor} # TODO: use federation_module instead of context_module?
    end
  end

  def get_actor_by_ap_id(ap_id) do
    with {:ok, %{username: username}} <- ActivityPub.Actor.get_cached_by_ap_id(ap_id) do
      get_actor_by_username(username)
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
      case APUtils.get_character_by_username(username) do
        {:ok, character} ->
          url = Bonfire.Me.Characters.character_url(character)
          if !String.contains?(url, "/404"), do: url

        _ ->
          nil
      end
    end
  end

  def update_local_actor(actor, params) do
    with {:ok, character} <- APUtils.get_character_by_ap_id(actor) do
      keys = e(params, :keys, nil)
      params = params
      |> Map.put(:character, %{id: character.id, actor: %{signing_key: keys}})
      # debug("update_local_actor: #{inspect character} with #{inspect params}")
      Bonfire.Common.ContextModules.maybe_apply(character, :update_local_actor, [character, params]) # FIXME use federation_module?
    end
  end

  # TODO: refactor & move to Me context(s)?
  def update_remote_actor(actor_object) do
    with data = actor_object.data,
         {:ok, character} <-
           APUtils.get_character_by_id(actor_object.pointer_id) do
      params = %{
        name: data["name"],
        summary: data["summary"],
        icon_id:
          APUtils.maybe_create_icon_object(
            APUtils.maybe_fix_image_object(data["icon"]),
            character
          ),
        image_id:
          APUtils.maybe_create_image_object(
            APUtils.maybe_fix_image_object(data["image"]),
            character
          )
      }

      # FIXME - support other types
      Bonfire.Me.Users.update_remote(character, params)
      :ok
    end
  end

  @doc """
  For updating an Actor in cache after a User/etc is updated
  """
  def update_local_actor_cache(character) do
    with %ActivityPub.Actor{} = actor <- Bonfire.Common.ContextModules.maybe_apply(character, :format_actor, character) do
      ActivityPub.Actor.set_cache(actor)
    end

    {:ok, character}
  end

  def maybe_create_remote_actor(actor) when not is_nil(actor) do
    log("AP - maybe_create_remote_actor for #{e(actor, :ap_id, nil) || e(actor, "id", nil)}")

    case APUtils.get_character_by_ap_id(actor) do

      {:ok, character} ->
        log("AP - remote actor already exists: #{character.id}")
        {:ok, character} # already exists

      {:error, _} -> # new character, create it...

        do_create_remote_actor(actor)
        #|> dump

    end
  end

  defp do_create_remote_actor(%{ap_id: ap_id}) when is_binary(ap_id), do: do_create_remote_actor(ap_id)
  defp do_create_remote_actor(%{"id"=> ap_id}) when is_binary(ap_id), do: do_create_remote_actor(ap_id)
  defp do_create_remote_actor(ap_id) when is_binary(ap_id) do
   case ActivityPub.Object.get_by_ap_id(ap_id) do
     %ActivityPub.Object{} = actor -> actor

     _ ->
      ActivityPub.Object.normalize(ap_id)
      # |> dump(ap_id)
      # |> e(:data, "id", nil)
      # |> dump
      # |> ActivityPub.Object.get_by_ap_id()
   end
   |> dump
   |> do_create_remote_actor()
  end
  # defp do_create_remote_actor(%{pointer_id: pointer_id}) when is_binary(pointer_id), do: ActivityPub.Object.get_by_pointer_id(pointer_id) |> do_create_remote_actor()
  defp do_create_remote_actor(%ActivityPub.Object{} = actor) do
    character_module = character_module(actor.data["type"])

    log("AP - do_create_remote_actor of type #{actor.data["type"]} with module #{character_module}")

    username = actor.data["preferredUsername"] <> "@" <> URI.parse(actor.data["id"]).host

    with {:ok, user_etc} <- repo().transact_with(fn ->
       with {:ok, peer} =  Bonfire.Federate.ActivityPub.Instances.get_or_create(actor),
            {:ok, user_etc} <- maybe_apply(character_module, [:create_remote, :create], %{
              character: %{
                username: username
              },
              profile: %{
                name: actor.data["name"],
                summary: actor.data["summary"]
              },
              peered: %{
                peer_id: peer.id,
                canonical_uri: actor.data["id"]
              }
            }),
            {:ok, _object} <- ActivityPub.Object.update(actor.id, %{pointer_id: user_etc.id}) |> dump do
        {:ok, user_etc}
      end
    end) do
      # debug(user_etc, "user created")

      # do this after the transaction, in case of timeouts downloading the images
      icon_id = APUtils.maybe_create_icon_object(APUtils.maybe_fix_image_object(actor.data["icon"]), user_etc)
      image_id = APUtils.maybe_create_image_object(APUtils.maybe_fix_image_object(actor.data["image"]), user_etc) #|> debug

      with {:ok, updated_user} <- maybe_apply(character_module, [:update_remote, :update],[user_etc, %{"profile" => %{"icon_id" => icon_id, "image_id" => image_id}}]) do
        {:ok, updated_user}
      else _ ->
        {:ok, user_etc}
      end
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

  def get_redirect_url(%{username: username}) when is_binary(username), do: get_redirect_url(username) |> debug
  def get_redirect_url(%{pointer_id: id}) when is_binary(id), do: get_redirect_url(id) |> debug
  def get_redirect_url(%{data: %{"id"=>id}}), do: get_redirect_url(id) |> debug

  def get_redirect_url(%{} = object), do: URIs.path(object) |> debug

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
        case APUtils.get_character_by_username(username) do
          {:ok, user_etc} -> URIs.path(user_etc)
          {:error, _} -> "/404"
        end
    end
  end

  def character_module(type) do
    with {:ok, module} <- Bonfire.Federate.ActivityPub.FederationModules.federation_module(type) do
      module
    else e ->
      log("AP - federation module not found (#{inspect e}) for type '#{type}', falling back to Users")
      Bonfire.Me.Users # fallback
    end
  end

end
