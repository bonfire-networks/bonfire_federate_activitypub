# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Adapter do
  @moduledoc """
  Adapter functions delegated from the `ActivityPub` Library
  """

  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  import AdapterUtils, only: [log: 1]

  use Bonfire.Common.Utils

  # alias Bonfire.Common.Needles
  alias Bonfire.Common.URIs
  alias Bonfire.Me.Characters
  # alias Bonfire.Federate.ActivityPub.Incoming
  alias ActivityPub.Actor

  import Bonfire.Federate.ActivityPub
  import Untangle

  @behaviour ActivityPub.Federator.Adapter

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
    |> debug("receive done")
  end

  defp character_id_from_actor(actor),
    do: e(actor, :pointer, nil) || actor.pointer_id || Characters.by_username!(actor.username)

  defp get_followers(%Actor{} = actor) do
    # debug(actor)
    character_id_from_actor(actor)
    |> debug("character")
    |> get_followers()
  end

  defp get_followers(character) do
    Bonfire.Social.Graph.Follows.all_subjects_by_object(character)
    # |> debug()
    |> Enum.map(&id(&1))
  end

  def get_follower_local_ids(actor) do
    # debug(actor)
    get_followers(actor)
    |> Enum.map(&id(&1))
  end

  def get_following_local_ids(actor) do
    with {:ok, character} <- Characters.by_username(actor.username) do
      Bonfire.Social.Graph.Follows.all_objects_by_subject(character)
      |> Enum.map(&id(&1))
    end
  end

  def external_followers_for_activity(actor, activity_data) do
    # debug(actor)
    # debug(activity_data)

    with ap_object when is_binary(ap_object) <-
           e(activity_data, "object", "id", nil) || e(activity_data, "object", nil),
         {:ok, object} <-
           ActivityPub.Object.get_cached(ap_id: ap_object),
         object when is_binary(object) or is_struct(object) <-
           e(object, :pointer, nil) || object.pointer_id,
         character when is_struct(character) or is_binary(character) <-
           character_id_from_actor(actor),
         followers when is_list(followers) and followers != [] <-
           get_followers(character)
           |> debug("followers")
           |> Enum.reject(&AdapterUtils.is_local?/1)
           |> debug("remote followers"),
         granted_followers when is_list(granted_followers) and granted_followers != [] <-
           Bonfire.Boundaries.users_grants_on(followers, object, [:see, :read]) do
      {:ok,
       granted_followers
       #  only positive grants
       |> Enum.filter(& &1.value)
       |> Enum.map(&Map.take(&1, [:subject_id]))
       |> debug("post_grants")
       |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1.subject_id))
       |> filter_empty([])
       |> debug("bcc actors based on grants")}
    else
      [] ->
        debug("No remote followers or grants")
        {:ok, []}

      e ->
        warn(e, "Could not find the object or actor?")
        {:ok, []}
    end
  end

  def get_actor_by_id(id) when is_binary(id) do
    with {:ok, character} <- AdapterUtils.get_character_by_id(id) |> debug() do
      get_actor_by_id(character)
    end
  end

  def get_actor_by_id(character) when is_struct(character) do
    with true <- AdapterUtils.is_local?(character) |> debug(),
         %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) |> debug() do
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
    AdapterUtils.get_local_actor_by_ap_id(ap_id)
    # case   AdapterUtils.get_actor_by_ap_id(ap_id) do
    #   nil ->
    #     debug(ap_id, "assume looking up a local character")

    #     with {:ok, character} <- AdapterUtils.get_local_character_by_ap_id(ap_id) do
    #       AdapterUtils.character_to_actor(character)
    #     end

    #   actor ->
    #     actor
    # end
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
    case AdapterUtils.get_or_fetch_character_by_ap_id(actor) do
      # {:error, :not_found} ->
      #   warn(actor, "no such character, but pretend all good for the case of user Tombstone")
      #   {:ok, actor}

      {:ok, %Bonfire.Data.Identity.Character{} = character} ->
        character_module =
          AdapterUtils.character_module(character)
          |> debug("character_module")

        character =
          character
          |> repo().maybe_preload(:actor)

        keys = e(params, :keys, nil) || e(character, :actor, :keys, nil)

        params =
          params
          |> deep_merge(%{actor: %{id: character.id, signing_key: keys}})

        AdapterUtils.maybe_add_aliases(
          character,
          e(params, :also_known_as, nil) || e(params, :data, "alsoKnownAs", nil)
        )

        maybe_apply(
          character_module,
          [:update_local_actor, :update],
          [character, params]
        )

      {:ok, user_etc} ->
        user_etc =
          user_etc
          |> repo().maybe_preload(character: [:actor])

        character_module =
          AdapterUtils.character_module(user_etc)
          |> debug("character_module")

        keys =
          e(params, :keys, nil) || e(user_etc, :character, :actor, :keys, nil) ||
            e(user_etc, :actor, :keys, nil)

        params =
          params
          |> deep_merge(%{
            character: %{id: user_etc.id, actor: %{id: user_etc.id, signing_key: keys}}
          })

        AdapterUtils.maybe_add_aliases(
          user_etc,
          e(params, :also_known_as, nil) || e(params, :data, "alsoKnownAs", nil)
        )

        # FIXME use federation_module?
        maybe_apply(
          character_module,
          [:update_local_actor, :update],
          [user_etc, params]
        )
    end
  end

  # TODO: refactor & move to Me context(s)?

  def update_remote_actor(%{pointer_id: pointer_id} = actor) when is_binary(pointer_id) do
    AdapterUtils.get_character_by_id(pointer_id)
    |> debug("character pre-update")
    ~> update_remote_actor(actor)
  end

  def update_remote_actor(actor) do
    AdapterUtils.get_or_fetch_character_by_ap_id(actor)
    |> debug("character pre-update")
    |> update_remote_actor(actor)
  end

  def update_remote_actor(%{} = character, %{data: data}),
    do: update_remote_actor(character, data)

  def update_remote_actor(%{} = character, data) do
    params =
      %{
        profile: %{
          name: data["name"],
          summary: data["summary"],
          location: e(data["location"], "name", nil),
          icon_id:
            AdapterUtils.maybe_create_icon_object(
              AdapterUtils.maybe_fix_image_object(data["icon"]),
              character
            ),
          image_id:
            AdapterUtils.maybe_create_banner_object(
              AdapterUtils.maybe_fix_image_object(data["image"]),
              character
            )
        }
      }
      |> debug("params")

    AdapterUtils.maybe_add_aliases(
      character,
      e(data, :also_known_as, nil) || e(params, "alsoKnownAs", nil)
    )

    # WIP - support types other than user
    case AdapterUtils.character_module(character) do
      nil ->
        Bonfire.Me.Users.update_remote_actor(character, params)

      character_module ->
        maybe_apply(character_module, [:update_remote_actor, :update], [
          character,
          params
        ])
    end
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
    log("AP - maybe_create_remote_actor for #{inspect(actor)}")

    case AdapterUtils.get_or_fetch_character_by_ap_id(actor) do
      {:ok, character} ->
        log("AP - remote actor exists, return it: #{id(character)}")
        # already exists
        {:ok, character}

      e ->
        error(e)
    end
  end

  def get_redirect_url(id_or_username_or_object)

  def get_redirect_url(id_or_username) when is_binary(id_or_username) do
    # IO.inspect(get_redirect_url: id_or_username)
    if is_ulid?(id_or_username) do
      URIs.path(id_or_username)
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

  def maybe_publish_object(pointer_id, manually_fetching?) when is_binary(pointer_id) do
    Bonfire.Common.Needles.get(pointer_id)
    ~> maybe_publish_object(manually_fetching?)
  end

  def maybe_publish_object(%{} = object, manually_fetching?) do
    object
    # |> info()
    |> Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(nil, :create, ...,
      manually_fetching?: true
    )
  end

  def get_or_create_service_actor() do
    case ActivityPub.Actor.get_cached(username: "activitypub_fetcher") do
      {:ok, actor} ->
        {:ok, actor}

      _ ->
        with %{} = character <- AdapterUtils.create_service_character(),
             %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
          {:ok, actor}
        else
          e ->
            error(e, "Cannot create service actor")
        end
    end
  end

  def get_locale, do: Bonfire.Common.Localise.get_locale_id()

  def federate_actor?(
        actor,
        direction \\ nil,
        by_actor \\ nil
      ) do
    case {AdapterUtils.get_character(actor),
          if(by_actor, do: AdapterUtils.get_character(by_actor))} do
      {{:ok, character}, {:ok, by_character}} ->
        Bonfire.Federate.ActivityPub.federating?(character) &&
          Bonfire.Federate.ActivityPub.federating?(by_character) &&
          !BoundariesMRF.actor_blocked?(
            character,
            direction,
            by_character
          ) &&
          !BoundariesMRF.actor_blocked?(
            by_character,
            direction,
            character
          )

      {{:ok, character}, _} ->
        Bonfire.Federate.ActivityPub.federating?(character) &&
          !BoundariesMRF.actor_blocked?(
            character,
            direction
          )

      {_, {:ok, by_character}} ->
        Bonfire.Federate.ActivityPub.federating?(by_character) &&
          !BoundariesMRF.actor_blocked?(
            by_character,
            direction
          )

      _ ->
        debug(actor, "no character for actor")
        Bonfire.Federate.ActivityPub.federating?()
    end
  end
end
