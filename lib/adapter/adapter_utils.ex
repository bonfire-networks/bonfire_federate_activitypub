# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.AdapterUtils do
  use Bonfire.Common.Utils
  # alias Bonfire.Common.URIs
  import Bonfire.Federate.ActivityPub
  alias Needle.Pointer
  alias ActivityPub.Actor
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Me.Users
  # alias Bonfire.Social.Threads
  alias Ecto.Association.NotLoaded
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.Incoming
  require Logger
  require ActivityPub.Config
  import Untangle

  @service_character_id "1ACT1V1TYPVBREM0TESFETCHER"
  @service_character_username "fediverse_user"

  def public_uri(), do: ActivityPub.Config.public_uri()

  def log(l) do
    # if Bonfire.Common.Config.get(:log_federation), do:
    Logger.info(inspect(l))
  end

  def ap_base_url() do
    Adapter.base_url() <>
      System.get_env("AP_BASE_PATH", "/pub")
  end

  def is_local?(thing, opts \\ [])

  def is_local?(thing, preload_if_needed) when is_boolean(preload_if_needed),
    do: is_local?(thing, preload_if_needed: preload_if_needed)

  def is_local?(thing, opts) do
    if is_binary(thing) do
      Bonfire.Common.Needles.one(thing, skip_boundary_check: true)
    else
      thing
    end
    # |> debug("thing")
    |> case do
      true ->
        true

      false ->
        false

      {:ok, thing} ->
        is_local?(thing, opts)

      %{id: @service_character_id} ->
        false

      %{is_local: true} ->
        true

      %Bonfire.Data.ActivityPub.Peered{} ->
        false

      %{peered: %Peered{}} ->
        false

      %{character: %{peered: %Peered{}}} ->
        false

      %{creator_id: @service_character_id} ->
        false

      %{creator: %{id: @service_character_id}} ->
        false

      %{creator: %{peered: %Peered{}}} ->
        false

      %{created: %{peered: %Peered{}}} ->
        false

      %{created: %{creator_id: @service_character_id}} ->
        false

      %{created: %{creator: %{id: @service_character_id}}} ->
        false

      %{created: %{creator: %{peered: %Peered{}}}} ->
        false

      %{peered: nil} ->
        true

      %{creator: %{peered: nil}} ->
        true

      %{created: %{creator: %{peered: nil}}} ->
        true

      %{created: %{peered: nil}} ->
        true

      %{character: %{peered: nil}} ->
        true

      %{user: %{peered: nil}} ->
        true

      object when is_struct(object) ->
        if opts[:preload_if_needed] != false do
          preload_peered(object)
          |> warn(
            "preloaded peered info (should try always doing this in original query to avoid n+1)"
          )
          |> is_local?(preload_if_needed: false)
        else
          warn(object, "no case matched for struct (maybe need to preload peered info)")
          true
        end

      other ->
        warn(other, "no case matched")
        true
    end
  end

  def preload_peered(object) do
    case object do
      %{peered: _, created: _} ->
        object
        |> repo().maybe_preload([:peered, created: [creator: :peered]])

      %{peered: _} ->
        object
        |> repo().maybe_preload(:peered)

      %{character: _} ->
        object
        |> repo().maybe_preload(character: :peered)

      %{creator: _} ->
        object
        |> repo().maybe_preload(creator: :peered)

      %{created: _} ->
        object
        |> repo().maybe_preload(created: [:peered, creator: :peered])

      %{user: _} ->
        object
        |> repo().maybe_preload(user: :peered)

      _ ->
        warn(object, "did not know how to preload peered")
        object
    end
  end

  def get_actor_username(%{preferred_username: u}) when is_binary(u), do: u
  def get_actor_username(%{username: u}) when is_binary(u), do: u

  def get_actor_username(%{character: %NotLoaded{}} = obj),
    do: get_actor_username(repo().maybe_preload(obj, character: [:peered]))

  def get_actor_username(%{character: c}), do: get_actor_username(c)
  def get_actor_username(u) when is_binary(u), do: u
  def get_actor_username(_), do: nil

  def get_character(q, opts \\ [])

  def get_character("http" <> _ = q, opts) do
    skip?(:ap_id, opts) || get_character_by_ap_id(q)
  end

  def get_character(q, opts) when is_binary(q) do
    skip?(:username, opts) || get_character_by_username(q)
  end

  def get_character(%struct{id: _} = character, _opts) when struct not in [Actor, Pointer] do
    {:ok, repo().maybe_preload(character, [:actor, :character, :profile])}
  end

  def get_character(%{pointer: %{id: _} = pointer}, _opts) do
    {:ok, repo().maybe_preload(pointer, [:actor, :profile, character: [:peered]])}
  end

  def get_character(%{pointer_id: pointer_id}, opts) when is_binary(pointer_id) do
    skip?(:id, opts) || get_character_by_id(pointer_id, opts)
  end

  def get_character(%{id: pointer_id} = object, opts) when is_binary(pointer_id) do
    if opts[:skip] != :id do
      get_character_by_id(pointer_id, opts)
    else
      case object do
        %Pointer{} ->
          {:ok, repo().maybe_preload(object, [:actor, :profile, character: [:peered]])}

        _ when is_struct(object) ->
          {:ok, object}

        %{__typename: Pointer} ->
          {:ok, object}

        other ->
          error(other, "unrecognised")
          {:error, :not_found}
      end
    end
  end

  def get_character(%{ap_id: q}, opts) when is_binary(q) do
    skip?(:ap_id, opts) || get_character_by_ap_id(q)
  end

  def get_character(%{username: q}, opts) when is_binary(q) do
    skip?(:username, opts) || get_character_by_username(q)
  end

  def get_character(q, _opts) do
    warn(q, "dunno how")
    {:error, :not_found}
  end

  defp skip?(type, opts) do
    if opts[:skip] == type, do: {:error, :not_found}
  end

  def get_character_by_username({:ok, c}), do: get_character_by_username(c)

  def get_character_by_username("@" <> username),
    do: get_character_by_username(username)

  def get_character_by_username(username) when is_binary(username) do
    with {:error, :not_found} <- Users.by_username(username) do
      debug(username, "not a user, check for any other character types")
      Bonfire.Common.Needles.get(username)
    end
    ~> get_character(skip: :username)

    # Bonfire.Common.Needles.get(username, [skip_boundary_check: true])
    # ~> get_character()
  end

  def get_character_by_username(other) do
    error(other, "Dunno how to look for character, attempt fallback to `get_character/1`")
    get_character(other, skip: :username)
  end

  def get_character_by_id(id, opts \\ [skip_boundary_check: true])

  def get_character_by_id(id, opts)
      when is_binary(id) do
    if pointer_id = uid(id) do
      Bonfire.Common.Needles.get(pointer_id, opts)
      ~> get_character(skip: :id)
    else
      error(id, "Expected a UID, attempt fallback to `get_character/1`")
      get_character(id, skip: :id)
    end
  end

  def get_character_by_id(other, opts) do
    error(other, "Dunno how to look for character, attempt fallback to `get_character/1`")
    get_character(other, skip: :id)
  end

  def get_character_by_ap_id(ap_id) when is_binary(ap_id) do
    local_instance = ap_base_url()

    case get_actor_by_ap_id(ap_id, local_instance) do
      nil ->
        debug(ap_id, "assume looking up a local character")
        get_local_character_by_ap_id(ap_id, local_instance)

      actor ->
        actor
        |> return_pointable()
    end
  end

  def get_character_by_ap_id(%{ap_id: ap_id}) when is_binary(ap_id) do
    get_character_by_ap_id(ap_id)
  end

  def get_character_by_ap_id(%{"id" => ap_id}) when is_binary(ap_id) when is_binary(ap_id) do
    get_character_by_ap_id(ap_id)
  end

  def get_character_by_ap_id(%{data: %{"id" => ap_id} = _data}) do
    get_character_by_ap_id(ap_id)
  end

  def get_character_by_ap_id(%{username: username} = actor) when is_binary(username) do
    get_character_by_username(ActivityPub.Actor.format_username(actor))
  end

  # def get_character_by_ap_id(%{username: username}) when is_binary(username) do
  #   get_character_by_username(username)
  # end
  # def get_character_by_ap_id(%{"preferredUsername" => username}) when is_binary(username) do
  #   get_character_by_username(username) |> info("preferredUsername: #{username}")
  # end

  def get_character_by_ap_id(other) do
    error(
      other,
      "Invalid parameters when looking up an actor, attempt fallback to `get_character/1`"
    )

    get_character(other, skip: :ap_id)
  end

  @doc "without :ok / :error tuple"
  def get_character_by_ap_id!(ap_id) do
    case get_character_by_ap_id(ap_id) do
      {:ok, character} -> character
      # TEMP
      %{} = character -> character
      _ -> nil
    end
  end

  def get_local_character_by_ap_id(ap_id, local_instance \\ nil) when is_binary(ap_id) do
    # FIXME: this is fragile as doesn't support hostname/port changes
    local_instance = debug(local_instance || ap_base_url())

    username =
      String.trim_leading(ap_id, "#{local_instance}/actors/")
      |> debug("username?")

    if username != ap_id and !is_local_collection_or_built_in?(ap_id),
      do:
        username
        |> get_character_by_username()
  end

  def is_local_collection_or_built_in?("https://www.w3.org/ns/activitystreams#Public"),
    do: true

  def is_local_collection_or_built_in?(ap_id),
    do: is_local_collection?(ap_id)

  def is_local_collection?(ap_id),
    do: String.ends_with?(ap_id, ["/followers", "/following", "/outbox", "/inbox"])

  def the_ap_id(%{ap_id: ap_id}) when is_binary(ap_id) do
    ap_id
  end

  def the_ap_id(%{"id" => ap_id}) when is_binary(ap_id) when is_binary(ap_id) do
    ap_id
  end

  def the_ap_id(%{data: %{"id" => ap_id} = _data}) do
    ap_id
  end

  def the_ap_id(ap_id) when is_binary(ap_id) do
    ap_id
  end

  def all_actors(activity) do
    actors =
      ([ed(activity, "actor", nil)] ++
         [ed(activity, "object", "actor", nil)] ++
         [ed(activity, "object", "attributedTo", nil)])
      |> List.flatten()
      |> filter_empty(nil)
      |> debug("found actors")

    # for actors themselves
    (actors || [activity])
    # |> debug
    # |> Enum.map(&id_or_object_id/1)
    # |> debug
    |> filter_empty([])
    # |> debug
    # |> Enum.uniq()
    |> Enum.uniq_by(&id_or_object_id/1)
    |> debug("final actors")
  end

  def all_recipients(activity, fields \\ [:to, :bto, :cc, :bcc, :audience]) do
    activity
    # |> debug
    |> all_fields(fields)
    |> debug()
  end

  defp all_fields(activity, fields) do
    fields
    # |> debug
    |> Enum.map(&id_or_object_id(ed(activity, &1, nil)))
    # |> debug
    |> List.flatten()
    |> filter_empty([])
    |> Enum.uniq()
  end

  def id_or_object_id(%{"id" => id}) when is_binary(id) do
    id
  end

  def id_or_object_id(%{object: %{"id" => id}}) when is_binary(id) do
    id
  end

  def id_or_object_id(id) when is_binary(id) do
    id
  end

  def id_or_object_id(objects) when is_list(objects) do
    Enum.map(objects, &id_or_object_id/1)
  end

  def id_or_object_id(nil) do
    nil
  end

  def id_or_object_id(%{character: %{peered: %{canonical_uri: id}}}) when is_binary(id) do
    id
  end

  def id_or_object_id(%{peered: %{canonical_uri: id}}) when is_binary(id) do
    id
  end

  def id_or_object_id(%{canonical_uri: id}) when is_binary(id) do
    id
  end

  def id_or_object_id(%{character: %{peered: nil}} = object) do
    debug(object, "local actor, so could not find AP ID - generate it instead")
    URIs.canonical_url(object)
  end

  def id_or_object_id(%{peered: nil} = object) do
    debug(object, "local actor, so could not find AP ID - generate it instead")
    URIs.canonical_url(object)
  end

  def id_or_object_id(%{actor: %{id: _}} = object) do
    debug(object, "local actor, so could not find AP ID - attempt to generate it instead")
    URIs.canonical_url(object)
  end

  def id_or_object_id(%{character: %{peered: %Ecto.Association.NotLoaded{}}} = object) do
    error(object, "peered not preloaded, so could not find AP ID")
    nil
  end

  def id_or_object_id(%{peered: %Ecto.Association.NotLoaded{}} = object) do
    error(object, "peered not preloaded, so could not find AP ID")
    nil
  end

  def id_or_object_id(other) do
    error(other, "could not find AP ID")
    nil
  end

  def is_follow?(%{"type" => "Follow"}) do
    true
  end

  def is_follow?(%{type: "Follow"}) do
    true
  end

  def is_follow?(_) do
    false
  end

  def local_actor_ids(actors) do
    # TODO: cleaner: and put in AdapterUtils
    # ap_base_uri = ActivityPub.Web.base_url() <> System.get_env("AP_BASE_PATH", "/pub")

    # |> debug("ap_base_uri")

    actors
    |> Enum.map(&id_or_object_id/1)
    |> Enum.reject(&is_local_collection_or_built_in?/1)
    |> Enum.uniq()
    # |> Enum.filter(&String.starts_with?(&1, ap_base_uri))
    # |> debug("before local_actor_ids")
    |> Enum.map(&maybe_pointer_for_ap_id/1)
    |> filter_empty([])
  end

  def maybe_pointer_for_ap_id(ap_id) do
    case ActivityPub.Object.get_cached(ap_id: ap_id) |> repo().maybe_preload(:pointer) do
      {:ok, %{pointer: %{id: _} = pointer}} ->
        {ap_id, pointer}

      {:ok, %{pointer_id: pointer_id}} when not is_nil(pointer_id) ->
        {ap_id, pointer_id}

      _ ->
        with {:ok, character} <- get_local_character_by_ap_id(ap_id) do
          {ap_id, character}
        else
          _ ->
            nil
        end
    end
  end

  def get_or_fetch_character_by_ap_id(actor_or_ap_id) do
    local_instance = ap_base_url()

    with {:error, :not_found} <- get_character_by_ap_id(actor_or_ap_id),
         ap_id when is_binary(ap_id) <- the_ap_id(actor_or_ap_id) || {:error, :not_found} do
      if not String.starts_with?(ap_id, local_instance) do
        debug(ap_id, "assume fetching remote character")
        # FIXME: this should not query the AP db
        # query Character.Peered instead? but what about if we're requesting a remote actor which isn't cached yet?
        ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
        |> info("got by ap_id")
        |> return_pointable()
      end
    end
  end

  def get_actor_by_ap_id(ap_id, local_instance \\ nil) when is_binary(ap_id) do
    local_instance = local_instance || ap_base_url()
    # only create Peer for remote instances
    if not String.starts_with?(ap_id, local_instance) do
      debug(ap_id, "assume looking up a known remote character")
      # FIXME: this should not query the AP db
      # query Character.Peered instead? but what about if we're requesting a remote actor which isn't cached yet?
      ActivityPub.Actor.get_cached(ap_id: ap_id)
      |> info("got by ap_id")
    else
      debug(ap_id, "assume looking up a local character")
      get_local_actor_by_ap_id(ap_id)
    end
  end

  def get_local_actor_by_ap_id(ap_id) do
    with {:ok, character} <- get_local_character_by_ap_id(ap_id) do
      character_to_actor(character)
    end
  end

  def get_by_url_ap_id_or_username(q, opts \\ [])

  def get_by_url_ap_id_or_username("@" <> username, opts),
    do: get_or_fetch_and_create_by_username(username, opts)

  def get_by_url_ap_id_or_username("http:" <> _ = url, opts),
    do: get_or_fetch_and_create_by_uri(url, opts)

  def get_by_url_ap_id_or_username("https:" <> _ = url, opts),
    do: get_or_fetch_and_create_by_uri(url, opts)

  def get_by_url_ap_id_or_username(string, opts) when is_binary(string) do
    if validate_url(string) do
      get_or_fetch_and_create_by_uri(string, opts)
    else
      get_or_fetch_and_create_by_username(string, opts)
    end
  end

  def get_or_fetch_and_create_by_username(q, opts \\ []) when is_binary(q) do
    if String.contains?(q, "@") do
      log("AP - get_cached_or_fetch(username: : " <> q)

      ActivityPub.Actor.get_cached_or_fetch(username: q)
      ~> return_pointable()
    else
      log("AP - get_character_by_username: " <> q)
      get_character_by_username(q)
    end
  end

  def get_or_fetch_and_create_by_uri(q, opts \\ []) when is_binary(q) do
    # TODO: support objects, not just characters
    if not String.starts_with?(
         q |> debug(),
         ap_base_url() |> debug()
       ) do
      # TODO: cleanup
      case URI.parse(q) do
        %{path: path, host: host} = uri when is_nil(path) or path == "/" ->
          log("AP - get_or_fetch_and_create_by_uri - assume remote instance with URI: " <> q)

          with {:error, _} <- Bonfire.Federate.ActivityPub.Instances.get_by_domain(host),
               %{} <-
                 ActivityPub.Instances.scrape_nodeinfo(uri) ||
                   error(:not_found, "Could not find nodeinfo"),
               {:ok, instance} <-
                 Bonfire.Federate.ActivityPub.Instances.get_or_create(
                   uri
                   |> Map.put(:scheme, "https")
                   |> Map.put(:path, nil)
                   |> URI.to_string()
                 ) do
            {:ok, instance}
          end

        _ ->
          log("AP - get_or_fetch_and_create_by_uri - assume remote object with URI : " <> q)

          case ActivityPub.Federator.Fetcher.fetch_object_from_id(q, opts)
               |> debug("fetch_object_from_id result") do
            {:ok, %{pointer: %{id: _} = pointable} = _ap_object} ->
              {:ok, pointable}

            {:ok, %{pointer_id: _pointer_id} = ap_object} ->
              return_pointable(ap_object)

            {:ok, %ActivityPub.Actor{} = actor} ->
              return_pointable(actor)

            {:ok, %ActivityPub.Object{} = object} ->
              # FIXME? for non-actors
              return_pointable(object)

            # {{:ok, object}, _actor} -> {:ok, object}
            {:ok, object} ->
              {:ok, object}

            e ->
              error(e)
          end
      end
    else
      log("AP - uri - get_character_by_ap_id: assume local : " <> q)
      get_or_fetch_character_by_ap_id(q)
    end
  end

  # expects an ActivityPub.Actor. tries to load the associated object:
  # * if pointer_id is present, use that
  # * else use the id in the object
  def return_pointable(f, opts \\ [skip_boundary_check: true])

  def return_pointable({:ok, fetched}, opts),
    do: return_pointable(fetched, opts)

  # FIXME: privacy
  def return_pointable(fetched, opts) do
    # info(fetched, "fetched")
    case fetched do
      %{pointer: %{id: _} = pointable} ->
        {:ok, pointable}

      %{pointer_id: id, data: %{"type" => "Tombstone"}} ->
        {:error, :not_found}

      %{pointer_id: id, data: %{"type" => type}}
      when is_binary(id) and ActivityPub.Config.is_in(type, :supported_actor_types) ->
        with {:error, :not_found} <- get_character_by_id(id) do
          # in case the local pointer was deleted
          create_remote_actor(fetched)
        end

      %{pointer_id: id} when is_binary(id) ->
        with {:error, :not_found} <- return_pointer(id, opts) do
          # in case the local pointer was deleted
          debug(fetched, "re-create pointer for remote")
          Incoming.receive_activity(fetched)
        end

      %ActivityPub.Actor{username: username} when is_binary(username) ->
        debug("we have a username")

        with {:error, :not_found} <-
               get_character_by_username(ActivityPub.Actor.format_username(fetched)) do
          create_remote_actor(fetched)
        end

      _ when is_binary(fetched) ->
        if is_uid?(fetched) do
          get_character_by_id(fetched)
        else
          error(fetched, "Don't know how to find this object")
        end

      # nope? let's try and find them from their ap id
      %ActivityPub.Actor{} ->
        create_remote_actor(fetched)

      %ActivityPub.Object{data: %{"type" => type}}
      when ActivityPub.Config.is_in(type, :supported_actor_types) ->
        create_remote_actor(fetched)

      %ActivityPub.Object{} ->
        debug(fetched, "re-create pointer for remote object")
        Incoming.receive_activity(fetched)

      %{id: _} ->
        {:ok, fetched}

      {:error, :not_found} ->
        error(fetched, "no Pointable found for")
        {:error, :not_found}

      other ->
        error(other, "unhandled case for return_pointable")
    end
  end

  def return_pointer(id, opts) do
    Bonfire.Common.Needles.get(uid(id), opts)
    # |> info("got")
    # actor_integration_test
    |> repo().maybe_preload([:actor, :character, :profile])
    |> repo().maybe_preload([:post_content])

    # |>
    # nope? let's try and find them from their ap id
    # |> debug
  end

  def validate_url(str) do
    uri = URI.parse(str)

    case uri do
      %URI{scheme: nil} -> false
      %URI{host: nil} -> false
      _uri -> true
    end
  end

  def get_object_or_actor_by_ap_id!(ap_id) when is_binary(ap_id) do
    log("AP - get_object_or_actor_by_ap_id! : " <> ap_id)
    # FIXME?
    ok_unwrap(ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)) ||
      ActivityPub.Object.get_cached!(ap_id: ap_id) || ap_id
  end

  def get_object_or_actor_by_ap_id!(ap_id) do
    ap_id
  end

  def get_creator_ap_id(%{creator_id: creator_id})
      when not is_nil(creator_id) do
    log("AP - get_creator_ap_id! : " <> creator_id)

    with {:ok, %{ap_id: ap_id}} <-
           ActivityPub.Actor.get_cached(pointer: creator_id) do
      ap_id
    else
      _ -> nil
    end
  end

  def get_creator_ap_id(_), do: nil

  def get_different_creator_ap_id(%{id: id, creator_id: creator_id} = character)
      when id != creator_id do
    get_creator_ap_id(character)
  end

  def get_different_creator_ap_id(_), do: nil

  def get_context_ap_id(%{context_id: context_id})
      when not is_nil(context_id) do
    log("AP - get_context_ap_id! : " <> context_id)

    with {:ok, %{ap_id: ap_id}} <-
           ActivityPub.Actor.get_cached(pointer: context_id) do
      ap_id
    else
      _ -> nil
    end
  end

  def get_context_ap_id(_), do: nil

  def character_to_actor(nil), do: nil

  def character_to_actor(character) do
    debug(character, "character")

    character_module(character)
    |> debug()
    |> maybe_apply_or(:format_actor, character)

    # with %ActivityPub.Actor{} = actor <-
    #        Bonfire.Common.ContextModule.maybe_apply(
    #          character,
    #          :format_actor,
    #          character
    #        ) do
    #   # TODO: use federation_module instead of context_module?
    #   actor
    # else
    #   e ->
    #     warn(e, "falling back on generic function")
    #     format_actor(character)
    # end
  end

  defp maybe_apply_or(type, fun, args, fallback_fn \\ nil)

  defp maybe_apply_or(type, fun, args, fallback_fn) when is_atom(type) and not is_nil(type) do
    with {:error, e} <-
           Bonfire.Common.ContextModule.maybe_apply(
             type,
             fun,
             args
           ) do
      warn(e, "falling back on generic function")

      apply_fun_style(fallback_fn || fun, args)
    end
  end

  defp maybe_apply_or(_, fun, args, fallback_fn), do: apply_fun_style(fallback_fn || fun, args)

  # TODO: put in generic place, maybe as part of maybe_apply
  def apply_fun_style(fallback_module \\ __MODULE__, fun, args) do
    case fun do
      fun when is_function(fun) -> apply(fun, List.wrap(args))
      {mod, fun} -> apply(mod, fun, List.wrap(args))
      fun when is_atom(fun) -> apply(fallback_module, fun, List.wrap(args))
      _ -> error("no function to run")
    end
  end

  def format_actor(user_etc, type \\ "Person")

  def format_actor(%struct{}, type)
      when struct == Bonfire.Data.AccessControl.Circle or type == "Circle",
      do: nil

  def format_actor(%{id: pointer_id} = user_etc, type) do
    user_etc =
      repo().maybe_preload(
        user_etc,
        character: [
          :peered
        ]
      )

    local? = if e(user_etc, :character, :peered, nil), do: false, else: true
    id = Bonfire.Common.URIs.canonical_url(user_etc)

    if local? do
      user_etc =
        repo().maybe_preload(
          user_etc,
          [
            :settings,
            :actor,
            # :tags,
            profile: [:image, :icon],
            character: [
              # FIXME? should we used aliased, aliased, or a cross-reference of both?
              aliases: [object: [:character]]
              # aliased: [object: [:character]]
            ]
          ]
        )
        # |> Bonfire.Common.Needles.Preload.maybe_preload_nested_pointers([character: [aliases: [:object]]])
        |> debug("preloaded_user_etc")

      # icon = maybe_format_image_object_from_path(Bonfire.Files.IconUploader.remote_url(user_etc.profile.icon))
      # image = maybe_format_image_object_from_path(Bonfire.Files.ImageUploader.remote_url(user_etc.profile.image))

      icon = maybe_format_image_object_from_path(Media.avatar_url(user_etc))
      image = maybe_format_image_object_from_path(Media.banner_url(user_etc))

      base_url = Bonfire.Common.URIs.base_url()
      ap_base_path = Bonfire.Common.Config.get(:ap_base_path, "/pub")

      aliases =
        case e(user_etc, :character, :aliases, [])
             |> Enum.map(&(ed(&1, :object, :character, nil) || ed(&1, :object, nil)))
             |> Enum.reject(&is_nil/1) do
          [] ->
            %{}

          list ->
            list
            # |> IO.inspect(label: "objjj")
            |> Bonfire.Common.Needles.list!(skip_boundary_check: true)
            |> Enum.group_by(fn
              %struct{} ->
                struct

              other ->
                warn(other, "unsupported data")
                :unknown
            end)
        end

      # |> IO.inspect(label: "aliaases")

      # aliased = e(user_etc, :character, :aliased, nil)

      location = e(user_etc, :profile, :location, nil)

      # TODO: actual update time?
      updated_at = NaiveDateTime.utc_now()

      data =
        %{
          "type" => type,
          "id" => id,
          "inbox" => "#{id}/inbox",
          "outbox" => "#{id}/outbox",
          "followers" => "#{id}/followers",
          "following" => "#{id}/following",
          "preferredUsername" => e(user_etc, :character, :username, nil),
          "name" => e(user_etc, :profile, :name, nil) || e(user_etc, :character, :username, nil),
          "summary" => Text.maybe_markdown_to_html(e(user_etc, :profile, :summary, nil)),
          "alsoKnownAs" =>
            if(also_known = Map.get(aliases, Bonfire.Data.Identity.Character),
              do: alias_actor_ids(also_known)
            ),
          "icon" => icon,
          "image" => image,
          "location" =>
            if(location,
              do: %{
                "name" => location,
                "type" => "Place"
                # "longitude"=> 12.34,
                # "latitude"=> 56.78,
              }
            ),
          "attachment" =>
            ([
               maybe_attach_property_value(
                 :website,
                 e(user_etc, :profile, :website, nil)
               ),
               maybe_attach_property_value(
                 l("Location"),
                 location
               )
             ] ++ alias_maybe_attach_property_values(Map.get(aliases, Bonfire.Files.Media)))
            |> filter_empty(nil),
          "endpoints" => %{
            "sharedInbox" => base_url <> ap_base_path <> "/shared_inbox",
            "oauthAuthorizationEndpoint" => base_url <> "/oauth/authorize",
            "oauthRegistrationEndpoint" => base_url <> "/api/v1/apps",
            "oauthTokenEndpoint" => base_url <> "/oauth/token"
          },
          # whether user should appear in directories and search engines
          "discoverable" =>
            Bonfire.Common.Settings.get([Bonfire.Me.Users, :undiscoverable], nil,
              current_user: user_etc
            ) !=
              true,
          "indexable" => Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer, user_etc),
          "updated" =>
            updated_at
            |> NaiveDateTime.to_iso8601()
        }
        |> debug("data")

      %Actor{
        id: user_etc.id,
        data: data,
        keys: e(user_etc, :actor, :signing_key, nil),
        local: local?,
        ap_id: id,
        pointer_id: user_etc.id,
        username: e(user_etc, :character, :username, nil),
        deactivated: false,
        updated_at: updated_at
      }
      |> debug("formatted")
    else
      with {:error, :not_found} <- Actor.get_cached(pointer: user_etc),
           {:error, :not_found} <- Actor.get_cached(ap_id: id) do
        error(user_etc, "Could not find remote Actor")
      end
    end
  end

  defp alias_actor_ids(aliases) when is_list(aliases) and aliases != [],
    do: Enum.map(aliases, &alias_actor_ids/1)

  defp alias_actor_ids(%{} = o), do: Bonfire.Common.URIs.canonical_url(o)
  defp alias_actor_ids(_), do: []

  defp alias_maybe_attach_property_values(aliases) when is_list(aliases) and aliases != [] do
    Enum.map(aliases, fn o ->
      uri = Bonfire.Common.URIs.canonical_url(o)

      maybe_attach_property_value(
        ed(o, :metadata, "label", nil) || ed(o, :media_type, nil) || ed(o, :username, nil) ||
          URIs.display_url(uri),
        uri
      )
    end)
  end

  defp alias_maybe_attach_property_values(_), do: []

  def create_remote_actor({:ok, a}),
    do: create_remote_actor(a)

  def create_remote_actor(%ActivityPub.Actor{} = actor) do
    character_module = character_module(actor.data["type"])

    log("AP - create_remote_actor of type #{actor.data["type"]} with module #{character_module}")
    debug(actor)

    # username = actor.data["preferredUsername"] <> "@" <> URI.parse(actor.data["id"]).host
    username = actor.username || actor.ap_id
    name = actor.data["name"]
    name = if empty?(name), do: username, else: name

    with {:error, :not_found} <- get_character_by_username(username),
         {:ok, user_etc} <-
           repo().transact_with(fn ->
             with {:ok, peer} <-
                    Bonfire.Federate.ActivityPub.Instances.get_or_create(actor),
                  {:ok, user_etc} <-
                    maybe_apply_or(
                      character_module,
                      [:create_remote, :create],
                      [
                        %{
                          character: %{
                            username: username
                          },
                          profile: %{
                            name: name,
                            summary: actor.data["summary"],
                            location: e(actor.data["location"], "name", nil)
                          },
                          peered: %{
                            peer_id: peer.id,
                            # peer: peer,
                            canonical_uri: actor.data["id"]
                          }
                        },
                        [
                          local: false,
                          #  FIXME: don't query again (Instances.get_or_create already has)
                          custom_circles: [
                            silence_my_instance:
                              Extend.maybe_module(Bonfire.Boundaries.Circles).get_or_create_stereotype_circle(
                                peer,
                                :silence_me
                              )
                          ]
                        ]
                      ],
                      # FIXME: should not depend on Users for fallback
                      &Bonfire.Me.Users.create_remote/1
                    ),
                  {:ok, _object} <-
                    ActivityPub.Object.update_existing(actor.id, %{
                      pointer_id: user_etc.id
                    }) do
               {:ok, user_etc}
             end
           end) do
      # debug(user_etc, "user created")

      # maybe save a Peer for instance and Peered URI
      Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
        user_etc,
        actor.data["id"],
        type: :actor
      )
      |> debug("saved peered")

      maybe_add_aliases(user_etc, e(actor, :data, "alsoKnownAs", nil))

      # save remote discoverability flag as a user setting
      if actor.data["discoverable"] in ["false", false, "no"],
        do:
          Bonfire.Common.Settings.put(
            [Bonfire.Me.Users, :undiscoverable],
            true,
            current_user: user_etc
          )

      # do this after the transaction, in case of timeouts downloading the images
      icon_id =
        maybe_create_icon_object(
          maybe_fix_image_object(actor.data["icon"]),
          user_etc
        )

      # |> debug
      banner_id =
        maybe_create_image_object(
          maybe_fix_image_object(actor.data["image"]),
          user_etc
        )

      with {:ok, updated_user} <-
             maybe_apply(character_module, [:update_remote_actor, :update], [
               user_etc,
               %{"profile" => %{"icon_id" => icon_id, "image_id" => banner_id}}
             ]) do
        {:ok, updated_user}
      else
        _ ->
          {:ok, user_etc}
      end
    end
  end

  def create_remote_actor(%{ap_id: ap_id}) when is_binary(ap_id),
    do: create_remote_actor(ap_id)

  def create_remote_actor(%{"id" => ap_id}) when is_binary(ap_id),
    do: create_remote_actor(ap_id)

  def create_remote_actor(ap_id) when is_binary(ap_id) do
    case ActivityPub.Object.get_cached!(ap_id: ap_id) do
      %ActivityPub.Object{} = object ->
        object

      _ ->
        ActivityPub.Object.normalize(ap_id)
    end
    #  |> debug
    |> create_remote_actor()
  end

  # def create_remote_actor(%{pointer_id: pointer_id}) when is_binary(pointer_id), do: ActivityPub.Object.get_cached!(pointer: pointer_id) |> create_remote_actor()
  def create_remote_actor(%ActivityPub.Object{} = object),
    do:
      ActivityPub.Actor.format_remote_actor(object)
      |> debug("cfa")
      |> create_remote_actor()

  def maybe_add_aliases(user_etc, aliases) do
    case aliases do
      nil ->
        debug("no alsoKnownAs provided")

      [] ->
        debug("empty alsoKnownAs provided")

      _ when is_list(aliases) ->
        Enum.each(aliases, &maybe_add_aliases(user_etc, &1))

      target ->
        debug(target, "add alsoKnownAs provided")

        get_or_fetch_character_by_ap_id(target)
        ~> Bonfire.Social.Graph.Aliases.add(user_etc, ...)
        |> debug("added??")
    end
  end

  def character_module(%{__struct__: Needle.Pointer} = struct),
    do: Types.object_type(struct) |> character_module()

  def character_module(%{__struct__: type}), do: character_module(type)
  def character_module(%{__typename: type}), do: character_module(type)

  def character_module(type) when is_atom(type) or is_binary(type) do
    with {:ok, module} <-
           Bonfire.Federate.ActivityPub.FederationModules.federation_module(type) do
      module
    else
      e ->
        log("AP - federation module not found (#{inspect(e)}) for type `#{type}`")

        # fallback?
        # Bonfire.Me.Users
        nil
    end
  end

  def determine_recipients(actor, comment) do
    determine_recipients(actor, comment, [public_uri()], [
      actor.data["followers"]
    ])
  end

  def determine_recipients(actor, comment, parent) do
    if(is_map(parent) and Map.has_key?(parent, :id)) do
      case ActivityPub.Actor.get_cached(pointer: parent.id) do
        {:ok, parent_actor} ->
          determine_recipients(
            actor,
            comment,
            [parent_actor.ap_id, public_uri()],
            [
              actor.data["followers"]
            ]
          )

        _ ->
          determine_recipients(actor, comment)
      end
    else
      determine_recipients(actor, comment)
    end
  end

  def determine_recipients(_actor, _comment, to, cc) do
    # this doesn't feel very robust
    # to =
    #   unless is_nil(get_in_reply_to(comment)) do
    #     # FIXME: replace with correct call
    #     participants =
    #       Threads.list_comments_in_thread(comment.thread)
    #       |> Enum.map(fn comment -> comment.creator_id end)
    #       |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
    #       |> Enum.filter(fn actor -> actor end)
    #       |> Enum.map(fn actor -> actor.ap_id end)

    #     (participants ++ to)
    #     |> Enum.dedup()
    #     |> List.delete(Map.get(Actor.get_cached!(pointer: actor.id), :ap_id))
    #   else
    #     to
    #   end

    {to, cc}
  end

  def get_in_reply_to(comment) do
    reply_to_id = Map.get(comment, :reply_to_id)

    if reply_to_id do
      case ActivityPub.Object.get_cached!(pointer: reply_to_id) do
        nil ->
          nil

        object ->
          object.data["id"]
      end
    else
      nil
    end
  end

  def get_object_ap_id(%{id: id}) do
    case ActivityPub.Actor.get_cached!(pointer: id) do
      %{ap_id: id} ->
        id

      %{data: %{"id" => id}} ->
        id

      _ ->
        case ActivityPub.Object.get_cached!(pointer: id) do
          %{data: %{"id" => id}} -> id
          e -> error(e)
        end
    end
  end

  def get_object_ap_id(_) do
    {:error, "No valid object provided to get_object_ap_id/1"}
  end

  def get_object_ap_id!(object) do
    with {:error, e} <- get_object_ap_id(object) do
      log("AP - get_object_ap_id!/1 - #{e}")
      nil
    end
  end

  def get_pointer_id_by_ap_id(ap_id) do
    case ActivityPub.Object.get_cached(ap_id: ap_id) do
      {:ok, object} ->
        object.pointer_id

      _ ->
        # Might be a local actor
        with {:ok, actor} <- ActivityPub.Actor.get_cached(ap_id: ap_id) do
          actor.pointer_id
        else
          _ -> nil
        end
    end
  end

  def create_author_object(%{author: nil}) do
    nil
  end

  def create_author_object(%{author: author}) do
    uri = URI.parse(author)

    if uri.host do
      %{"url" => author, "type" => "Person"}
    else
      %{"name" => author, "type" => "Person"}
    end
  end

  def get_author(nil), do: nil

  def get_author(%{"url" => url}), do: url

  def get_author(%{"name" => name}), do: name

  def get_author(author) when is_binary(author), do: author

  def maybe_fix_image_object(url) when is_binary(url), do: url
  def maybe_fix_image_object(%{"url" => url}), do: url
  def maybe_fix_image_object(_), do: nil

  # def maybe_create_image_object(nil), do: nil

  # def maybe_create_image_object(url) do
  #   %{
  #     "type" => "Image",
  #     "url" => url
  #   }
  # end

  def maybe_create_banner_object(nil, _actor), do: nil

  def maybe_create_banner_object(url, actor) do
    maybe_upload(Bonfire.Files.ImageUploader, url, actor)
  end

  def maybe_create_image_object(nil, _actor), do: nil

  def maybe_create_image_object(url, actor) do
    maybe_upload(Bonfire.Files.BannerUploader, url, actor)
  end

  def maybe_format_image_object_from_path("http" <> _ = url) do
    %{
      "type" => "Image",
      "url" => url
    }
  end

  def maybe_format_image_object_from_path(path) when is_binary(path) do
    %{
      "type" => "Image",
      "url" => Bonfire.Federate.ActivityPub.Adapter.base_url() <> path
    }
  end

  def maybe_format_image_object_from_path(_), do: nil

  def maybe_attach_property_value(key, "http" <> _ = url)
      when is_binary(url),
      do: property_value(key || l("Website"), "<a rel=\"me\" href=\"#{url}\">#{url}</a>")

  def maybe_attach_property_value(:website, url) when is_binary(url),
    do: maybe_attach_property_value(nil, "http://" <> url)

  def maybe_attach_property_value(key, value) when is_binary(value),
    do: property_value(to_string(key), value)

  def maybe_attach_property_value(_, _), do: nil

  defp property_value(name, value) do
    %{
      "name" => name,
      "type" => "PropertyValue",
      "value" => value
    }
  end

  def maybe_create_icon_object(nil, _actor), do: nil

  def maybe_create_icon_object(url, actor) do
    maybe_upload(Bonfire.Files.IconUploader, url, actor)
  end

  defp maybe_upload(adapter, url, %{} = actor) do
    debug(url)

    with {:ok, %{id: id}} <-
           Bonfire.Files.upload(adapter || Bonfire.Files.ImageUploader, actor, url, %{},
             skip_fetching_remote: true
           ) do
      id
    else
      _ ->
        nil
    end
  end

  # @service_character_id
  def service_character_id, do: Bonfire.Me.Users.remote_fetcher_id()
  def service_character_username, do: @service_character_username

  def get_or_create_service_character(
        service_character_id \\ service_character_id(),
        service_character_username \\ service_character_username()
      ) do
    Bonfire.Me.Users.get_or_create_service_character(
      service_character_id,
      service_character_username
    )
  end

  defp create_service_character(
         service_character_id \\ service_character_id(),
         service_character_username \\ service_character_username()
       ) do
    Bonfire.Me.Users.create_service_character(service_character_id, service_character_username)
  end
end
