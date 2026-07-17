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
  alias Bonfire.Federate.ActivityPub.Incoming
  alias Bonfire.Federate.ActivityPub.Outgoing
  alias ActivityPub.Actor
  alias ActivityPub.Object

  import Bonfire.Federate.ActivityPub, except: [federation_allowed?: 2]
  import Untangle

  @behaviour ActivityPub.Federator.Adapter

  def base_url() do
    Bonfire.Common.URIs.base_url()
  end

  def get_multi_tenant_context do
    Bonfire.Common.TestInstanceRepo.get_parent_instance_meta()
  end

  def set_multi_tenant_context(context) do
    Bonfire.Common.TestInstanceRepo.set_child_instance(context)
  end

  @doc """
  Process incoming activities
  """
  def handle_activity(activity) do
    # Incoming.Worker.enqueue("handle_activity", %{
    #   "activity_id" => activity.id
    #   # "activity" => activity
    # })

    # case
    Incoming.receive_activity(activity)
    # |> debug("receive done") do
    #   nil -> activity
    #   received -> received
    # end
  end

  # Generic collection read: route by collection type to the owning extension's FederationModule
  # (e.g. Pins owns "featured"), which supplies the member ap_ids / count. Returns `nil` for any
  # collection type no module claims, so the AP lib falls back to its GenericCollectionStore
  # (used by keyPackages). Keeps this adapter free of per-collection (Pins-specific) logic.
  # Owning module returns its members as **local pointer ids** (its natural shape); this adapter
  # shapes them to what serving/delivery asked for via `opts[:return]`:
  # `:ap_ids` (default — cheap canonical URLs, no AP object build), `:ap_objects` (loaded
  # `%ActivityPub.Object{}`), `:pointer_ids` (as-is), `:pointers` (loaded host pointers/objects).
  def collection_items(%Object{} = collection, opts \\ []) do
    case collection_via_module(collection, :collection_items, opts) do
      pointer_ids when is_list(pointer_ids) -> shape_members(pointer_ids, opts[:return])
      _ -> nil
    end
  end

  def collection_total(%Object{} = collection, opts \\ []),
    do: collection_via_module(collection, :collection_total, opts)

  defp shape_members(pointer_ids, :pointer_ids), do: pointer_ids

  defp shape_members(pointer_ids, :pointers),
    do: Bonfire.Common.Needles.list!(pointer_ids, skip_boundary_check: true)

  defp shape_members(pointer_ids, :ap_objects), do: Object.list_cached(pointer_ids)

  defp shape_members(pointer_ids, _ap_ids) do
    # load + preload each member's locality assocs at SOURCE so `canonical_url` doesn't trip the
    # preload-at-source guard per member (collection members are mixed types — pinned objects and
    # actors — hence the superset + `prune: true`)
    shape_members(pointer_ids, :pointers)
    |> repo().maybe_preload([:peered, character: [:peered], created: [:peered]], prune: true)
    |> Enum.map(&URIs.canonical_url/1)
    |> Enum.reject(&is_nil/1)
  end

  # cheap registry lookup (no fetching): does any FederationModule handle this query? Used by the
  # lib to infer routing (e.g. store-backed collections are those no adapter handles).
  def adapter_handles?(query),
    do: match?({:ok, _}, Bonfire.Federate.ActivityPub.FederationModules.federation_module(query))

  defp collection_via_module(%{data: %{"id" => id}} = collection, fun, opts) do
    with {:ok, type, _uuid} <- ActivityPub.Utils.parse_collection_ap_id(id),
         {:ok, module} <-
           Bonfire.Federate.ActivityPub.FederationModules.federation_module({:collection, type}) do
      maybe_apply(module, fun, [collection, opts], fallback_return: nil)
    else
      _ -> nil
    end
  end

  defp collection_via_module(_collection, _fun, _opts), do: nil

  def get_follower_local_ids(actor, purpose_or_current_actor \\ nil) do
    # debug(actor)
    AdapterUtils.get_followers(actor, purpose_or_current_actor, :subject_id_only)
    |> List.flatten()

    # |> Enum.map(&id(&1))
  end

  def get_following_local_ids(%Actor{} = actor, purpose_or_current_actor \\ nil) do
    with {:ok, character} <- Characters.by_username(actor.username) do
      maybe_apply(
        Bonfire.Social.Graph.Follows,
        :all_objects_by_subject,
        [character, AdapterUtils.set_list_follow_opts(purpose_or_current_actor, :object_id_only)],
        fallback_return: []
      )
      |> List.flatten()

      # |> Enum.map(&id(&1))
    end
  end

  def external_followers_for_activity(actor, activity_data, addressed_pointer_ids \\ []) do
    with ap_object when is_binary(ap_object) <-
           e(activity_data, "object", "id", nil) || e(activity_data, "object", nil),
         {:ok, object} <-
           ActivityPub.Object.get_cached(ap_id: ap_object),
         object when is_binary(object) or is_struct(object) <-
           e(object, :pointer, nil) || object.pointer_id,
         character when is_struct(character) or is_binary(character) <-
           AdapterUtils.character_id_from_actor(actor) |> info("character_id_from_actor"),
         federation_mode when is_atom(federation_mode) and not is_nil(federation_mode) <-
           Bonfire.Federate.ActivityPub.federation_mode(character)
           |> info("external_followers_for_activity:federation_mode"),
         # preload `subject.character.peered` so the `is_local?` reject below classifies each
         # follower's locality without an on-demand (raising) preload
         followers when is_list(followers) and followers != [] <-
           AdapterUtils.get_followers(character, :activity, :subject_character_peered,
             exclude_ids: addressed_pointer_ids
           )
           |> debug("got_followers (excluding already addressed)")
           |> Enum.reject(&AdapterUtils.is_local?/1)
           |> debug("remote followers"),
         granted_followers when is_list(granted_followers) and granted_followers != [] <-
           Bonfire.Boundaries.users_grants_on(followers, object, [:see, :read]) do
      {:ok,
       granted_followers
       #  only positive grants
       |> Enum.filter(& &1.value)
       |> Enum.map(&Map.take(&1, [:subject_id]))
       # Skip granted followers already in addressed recipients
       |> Enum.reject(&(&1.subject_id in addressed_pointer_ids))
       |> debug("post_grants (excluding already addressed)")
       |> Enum.map(& &1.subject_id)
       |> ActivityPub.Actor.list_cached()
       |> Enum.filter(
         &Bonfire.Federate.ActivityPub.federation_allowed?(&1,
           current_user: character,
           federation_mode: federation_mode
         )
       )}
    else
      [] ->
        debug(actor, "No remote followers or grants")
        {:ok, []}

      e ->
        warn(e, "Could not find the object or actor?")
        debug(actor, "actor")
        debug(activity_data, "activity")
        {:ok, []}
    end
    |> debug("bcc actors based on grants")
  end

  def get_actor_by_id(id) when is_binary(id) do
    with {:ok, character} <- AdapterUtils.get_character_by_id(id) |> debug(id) do
      get_actor_by_id(character)
    end
  end

  def get_actor_by_id(%{id: id} = character) when is_struct(character) do
    with true <- AdapterUtils.is_local?(character) or id == AdapterUtils.service_character_id(),
         %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
      {:ok, actor}
    end
  end

  # batch sibling of `get_actor_by_id/1` (for `Actor.list_cached/2`): one `Needles.list!` + preload,
  # then format each local character. `skip_boundary_check: true` matches the single
  # `get_character_by_id` default for federation actor resolution.
  def get_actors_by_ids(ids) when is_list(ids) do
    ids
    |> Bonfire.Common.Needles.list!(skip_boundary_check: true)
    # preload what actor formatting needs, at the source and BEFORE `character_to_actor` (mirroring the single-actor `get_character` path): `character: [:peered]` for locality + the ULID `canonical_url`, and `:shared_user` so it's typed Person vs Organization
    |> repo().maybe_preload([:actor, :settings, :profile, :shared_user, character: [:peered]])
    |> Enum.flat_map(fn character ->
      # `character_to_actor` → `format_actor` accepts the (virtual) pointer directly; non-locals nil
      case AdapterUtils.character_to_actor(character) do
        %ActivityPub.Actor{} = actor -> [actor]
        _ -> []
      end
    end)
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

        keys =
          e(params, :keys, nil) ||
            e(character, :actor, :keys, nil)

        params =
          prepare_local_actor_params(character, params)
          |> deep_merge(%{actor: %{id: character.id, signing_key: keys}})

        maybe_apply(
          character_module,
          [:update_local_actor, :update],
          [character, params]
        )

      {:ok, user_etc} ->
        character_module =
          AdapterUtils.character_module(user_etc)
          |> debug("character_module")

        user_etc =
          user_etc
          |> repo().maybe_preload(character: [:actor])

        keys =
          e(params, :keys, nil) || e(user_etc, :character, :actor, :keys, nil) ||
            e(user_etc, :actor, :keys, nil)

        params =
          prepare_local_actor_params(user_etc, params)
          |> deep_merge(%{
            character: %{id: user_etc.id, actor: %{id: user_etc.id, signing_key: keys}}
          })

        # FIXME use federation_module?
        maybe_apply(
          character_module,
          [:update_local_actor, :update],
          [user_etc, params]
        )

      other ->
        error(other, "Could not find actor to update")
    end
  end

  defp prepare_local_actor_params(user_etc, params) do
    data = e(params, :data, nil) || params

    character_module =
      AdapterUtils.character_module(user_etc)
      |> debug("character_module")

    key_packages = e(params, :key_packages, nil) || e(data, "keyPackages", nil)

    AdapterUtils.maybe_add_aliases(
      user_etc,
      e(params, :also_known_as, nil) || e(data, "alsoKnownAs", nil)
    )

    if is_nil(key_packages),
      do: params,
      else:
        params
        |> deep_merge(%{extra_info: %{id: user_etc.id, info: %{"keyPackages" => key_packages}}})
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

  def update_remote_actor(%struct{} = actor, params) when struct in [Actor, Object] do
    AdapterUtils.get_or_fetch_character_by_ap_id(actor)
    |> debug("character pre-update")
    |> update_remote_actor(params)
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
  def local_actor_updated(character, is_local?) when not is_nil(character) do
    with %ActivityPub.Actor{} = actor <- AdapterUtils.character_to_actor(character) do
      ActivityPub.Actor.set_cache(actor)

      if is_local?,
        do:
          Outgoing.push_actor_update(character)
          |> debug("federated actor Update")
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
    if is_uid?(id_or_username) do
      URIs.path(id_or_username)
    else
      get_url_by_username(id_or_username)
    end
  end

  def get_redirect_url(%{username: username}) when is_binary(username),
    do: get_url_by_username(username)

  def get_redirect_url(%{pointer: %{id: id} = pointable}),
    do: URIs.path(pointable)

  def get_redirect_url(%{pointer_id: id}) when is_binary(id),
    do: URIs.path(id)

  def get_redirect_url(%{object: %{id: id} = object}),
    do: get_redirect_url(object)

  def get_redirect_url(%{data: %{"object" => object}}) when not is_nil(object) do
    with {:ok, object} <- Object.get_cached(ap_id: object) do
      get_redirect_url(object)
    else
      _e -> nil
    end
  end

  def get_redirect_url(%{data: %{"id" => id}}) when is_binary(id),
    do: get_redirect_url(id)

  def get_redirect_url(%{} = object), do: URIs.path(object)

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

  def maybe_publish_object(pointer_id, opts) when is_binary(pointer_id) do
    Bonfire.Common.Needles.get(pointer_id, opts)
    |> debug("maybe_publish_object lookup")
    ~> maybe_publish_object(opts)
  end

  def maybe_publish_object(%{} = object, opts) do
    object
    # |> info()
    |> Outgoing.maybe_federate(nil, :create, ..., opts)
  end

  def get_or_create_service_actor() do
    case ActivityPub.Actor.get_cached(pointer: AdapterUtils.service_character_id()) do
      {:ok, actor} ->
        {:ok, actor}

      _ ->
        with %{} = character <- AdapterUtils.get_or_create_service_character(),
             %ActivityPub.Actor{} = actor <-
               AdapterUtils.character_to_actor(character) |> debug("service actor"),
             {:ok, actor} <- ActivityPub.Safety.Keys.ensure_keys_present(actor) do
          {:ok, actor}
        else
          e ->
            error(e, "Cannot create service actor")
        end
    end
  end

  def get_locale, do: Bonfire.Common.Localise.get_locale_id()

  def federate_actor?(actor, direction \\ nil, by_actor \\ nil),
    do: federation_allowed?(actor, direction: direction, by_actor: by_actor)

  def transform_outgoing(data, target_host \\ nil, target_actor_id \\ nil)

  def transform_outgoing(%{"image" => image} = data, target_host, target_actor_id)
      when not is_nil(image) and image != [] do
    # debug(data, "img transform_outgoing")
    data
    |> Map.put(
      "image",
      maybe_apply(
        Bonfire.Files,
        :ap_transform_url,
        [image, target_host, target_actor_id],
        fallback_return: image
      )
    )
  end

  def transform_outgoing(%{"attachment" => attachment} = data, target_host, target_actor_id)
      when not is_nil(attachment) and attachment != [] do
    # debug(data, "att transform_outgoing")
    data
    |> Map.put(
      "attachment",
      maybe_apply(
        Bonfire.Files,
        :ap_transform_url,
        [attachment, target_host, target_actor_id],
        fallback_return: attachment
      )
    )
  end

  def transform_outgoing(data, _, _) do
    # debug(data, "WIP transform_outgoing")
    data
  end

  def federation_allowed?(subject, opts \\ []),
    do: Bonfire.Federate.ActivityPub.federation_allowed?(subject, opts)
end
