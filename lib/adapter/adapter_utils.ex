# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.AdapterUtils do
  use Bonfire.Common.Utils
  # alias Bonfire.Common.URIs
  import Bonfire.Federate.ActivityPub
  alias ActivityPub.Actor
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Me.Users
  # alias Bonfire.Social.Threads
  alias Ecto.Association.NotLoaded
  alias Bonfire.Federate.ActivityPub.Adapter
  require Logger
  import Untangle

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  def public_uri(), do: @public_uri

  def log(l) do
    # if Bonfire.Common.Config.get(:log_federation), do:
    Logger.info(inspect(l))
  end

  def ap_base_url() do
    Adapter.base_url() <>
      System.get_env("AP_BASE_PATH", "/pub")
  end

  def is_local?(thing) do
    if is_binary(thing) do
      Bonfire.Common.Pointers.one(thing, skip_boundary_check: true)
    else
      thing
    end
    # NOTE: trying preloads seperately so the whole thing doesn't fail if a field doesn't exists on the thing (TODO: pattern matching for schema could avoid this)
    |> repo().maybe_preload(:peered)
    |> repo().maybe_preload(character: :peered)
    |> repo().maybe_preload(creator: :peered)
    |> repo().maybe_preload(created: [:peered, creator: :peered])
    |> case do
      %{is_local: true} ->
        true

      %{peered: %Peered{}} ->
        false

      %{character: %{peered: %Peered{}}} ->
        false

      %{creator: %{peered: %Peered{}}} ->
        false

      %{created: %{peered: %Peered{}}} ->
        false

      %{created: %{creator: %{peered: %Peered{}}}} ->
        false

      thing when is_map(thing) ->
        # info(thing, "declaring local")
        true

      _ ->
        false
    end
    |> debug(ulid(thing))
  end

  def get_actor_username(%{preferred_username: u}) when is_binary(u), do: u
  def get_actor_username(%{username: u}) when is_binary(u), do: u

  def get_actor_username(%{character: %NotLoaded{}} = obj),
    do: get_actor_username(repo().maybe_preload(obj, :character))

  def get_actor_username(%{character: c}), do: get_actor_username(c)
  def get_actor_username(u) when is_binary(u), do: u
  def get_actor_username(_), do: nil

  def get_character_by_username({:ok, c}), do: get_character_by_username(c)

  def get_character_by_username(character) when is_struct(character),
    do: {:ok, repo().maybe_preload(character, [:actor, :character, :profile])}

  def get_character_by_username("@" <> username),
    do: get_character_by_username(username)

  def get_character_by_username(username) when is_binary(username) do
    with {:error, :not_found} <- Users.by_username(username) do
      info(username, "not a user, check for any other character types")
      Bonfire.Common.Pointers.get(username)
    end
    ~> get_character_by_username()

    # Bonfire.Common.Pointers.get(username, [skip_boundary_check: true])
    # ~> get_character_by_username()
  end

  def get_character_by_username(other),
    do: error(other, "Could not find character")

  def get_character_by_id(id, opts \\ [skip_boundary_check: true])

  def get_character_by_id(%{id: _} = c, _opts) do
    {:ok, c}
  end

  def get_character_by_id(id, opts)
      when is_binary(id) do
    pointer_id = ulid(id)

    if pointer_id do
      Bonfire.Common.Pointers.get(pointer_id, opts)
      ~> get_character_by_username()
    end
  end

  def get_local_character_by_ap_id(ap_id, local_instance \\ nil) when is_binary(ap_id) do
    String.trim_leading(ap_id, (local_instance || ap_base_url()) <> "/actors/")
    |> info("assume local character")
    |> get_character_by_username()
  end

  def get_character_by_ap_id(ap_id) when is_binary(ap_id) do
    local_instance = ap_base_url() |> info
    # only create Peer for remote instances
    if not String.starts_with?(ap_id, local_instance) do
      info(ap_id, "assume remote character")
      # FIXME: this should not query the AP db
      # query Character.Peered instead? but what about if we're requesting a remote actor which isn't cached yet?
      case ActivityPub.Actor.get_or_fetch_by_ap_id(ap_id, false)
           |> info("got_fetched_by_ap_id") do
        {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) ->
          get_character_by_id(pointer_id)

        {:ok, %{username: username} = actor} when is_binary(username) ->
          get_character_by_username(ActivityPub.Actor.format_username(actor))

        e ->
          error(e, "Could not fetch the actor")
      end
    else
      get_local_character_by_ap_id(ap_id, local_instance)
    end
  end

  def get_character_by_ap_id(%{pointer: %{id: _} = pointer}) do
    {:ok, pointer}
  end

  def get_character_by_ap_id(%{pointer_id: pointer_id}) when is_binary(pointer_id) do
    get_character_by_id(pointer_id)
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
  def get_character_by_ap_id(%{} = character) when is_struct(character),
    do: {:ok, repo().maybe_preload(character, [:actor, :character, :profile])}

  def get_character_by_ap_id(other) do
    error(other, "Invalid parameters when looking up an actor")
  end

  # def get_character_by_ap_id!(ap_id) do
  #   case get_character_by_ap_id(ap_id) do
  #     {:ok, character} -> character
  #     %{} = character -> character
  #     _ -> nil
  #   end
  # end

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

  defp get_or_fetch_and_create_by_username(q, opts) when is_binary(q) do
    if String.contains?(q, "@") do
      log("AP - get_or_fetch_by_username: " <> q)

      ActivityPub.Actor.get_or_fetch_by_username(q, opts)
      ~> return_character()
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
      log("AP - get_or_fetch_and_create_by_uri - assume remote with URI : " <> q)

      # TODO: cleanup
      case ActivityPub.Fetcher.fetch_object_from_id(q, opts)
           |> debug("fetch_object_from_id result") do
        {:ok, %{pointer: %{id: _} = pointable} = _ap_object} ->
          {:ok, pointable}

        {:ok, %{pointer_id: pointer_id} = _ap_object} when is_binary(pointer_id) ->
          # FIXME? for non-actors
          return_character(pointer_id)

        {:ok, %ActivityPub.Actor{} = actor} ->
          return_character(actor)

        {:ok, %ActivityPub.Object{} = object} ->
          # FIXME? for non-actors
          return_character(object)

        # {{:ok, object}, _actor} -> {:ok, object}
        {:ok, object} ->
          {:ok, object}

        e ->
          error(e)
      end
    else
      log("AP - uri - get_character_by_ap_id: assume local : " <> q)
      get_character_by_ap_id(q)
    end
  end

  # expects an ActivityPub.Actor. tries to load the associated object:
  # * if pointer_id is present, use that
  # * else use the id in the object
  defp return_character(f, opts \\ [skip_boundary_check: true])

  defp return_character({:ok, fetched}, opts),
    do: return_character(fetched, opts)

  # FIXME: privacy
  defp return_character(fetched, opts) do
    # info(fetched, "fetched")
    case fetched do
      %{pointer: %{id: _} = character} ->
        {:ok, character}

      %{pointer_id: id} when is_binary(id) ->
        return_pointer(id, opts)

      _ when is_binary(fetched) ->
        return_pointer(fetched, opts)

      # nope? let's try and find them from their ap id
      %ActivityPub.Actor{} ->
        get_character_by_ap_id(fetched)

      %ActivityPub.Object{} ->
        get_character_by_ap_id(fetched)

      %{id: _} ->
        {:ok, fetched}

      other ->
        other
    end
  end

  def return_pointer(id, opts) do
    Bonfire.Common.Pointers.get(ulid(id), opts)
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
    ok_unwrap(ActivityPub.Actor.get_or_fetch_by_ap_id(ap_id: ap_id)) ||
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

  def character_to_actor(character) do
    # debug(character, "character")

    character_module(character)
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

  # TODO: put in generic place, maybe as part of maybe_apply
  def maybe_apply_or(module, fun, args, fallback_fn \\ nil) do
    with {:error, e} <-
           Bonfire.Common.ContextModule.maybe_apply(
             module,
             fun,
             args
           ) do
      warn(e, "falling back on generic function")

      case fallback_fn || fun do
        fun when is_function(fun) -> apply(fun, List.wrap(args))
        {mod, fun} -> apply(mod, fun, List.wrap(args))
        fun when is_atom(fun) -> apply(__MODULE__, fun, List.wrap(args))
      end
    end
  end

  def format_actor(user_etc, type \\ "Person")

  def format_actor(%struct{}, type)
      when struct == Bonfire.Data.AccessControl.Circle or type == "Circle",
      do: nil

  def format_actor(%{} = user_etc, type) do
    user_etc =
      repo().preload(user_etc,
        profile: [:image, :icon],
        character: [:actor],
        peered: []
      )

    ap_base_path = Bonfire.Common.Config.get(:ap_base_path, "/pub")

    id = Bonfire.Common.URIs.maybe_generate_canonical_url(user_etc)

    # icon = maybe_format_image_object_from_path(Bonfire.Files.IconUploader.remote_url(user_etc.profile.icon))
    # image = maybe_format_image_object_from_path(Bonfire.Files.ImageUploader.remote_url(user_etc.profile.image))

    icon = maybe_format_image_object_from_path(Media.avatar_url(user_etc))
    image = maybe_format_image_object_from_path(Media.banner_url(user_etc))

    local = if user_etc.peered, do: false, else: true

    data = %{
      "type" => type,
      "id" => id,
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox",
      "followers" => "#{id}/followers",
      "following" => "#{id}/following",
      "preferredUsername" => e(user_etc, :character, :username, nil),
      "name" => e(user_etc, :profile, :name, nil) || e(user_etc, :character, :username, nil),
      "summary" => Text.maybe_markdown_to_html(e(user_etc, :profile, :summary, nil)),
      "icon" => icon,
      "image" => image,
      "attachment" =>
        filter_empty(
          [
            maybe_attach_property_value(
              :website,
              e(user_etc, :profile, :website, nil)
            ),
            maybe_attach_property_value(
              l("Location"),
              e(user_etc, :profile, :location, nil)
            )
          ],
          []
        ),
      "endpoints" => %{
        "sharedInbox" => Bonfire.Common.URIs.base_url() <> ap_base_path <> "/shared_inbox"
      },
      # whether user should appear in directories and search engines
      "discoverable" =>
        Bonfire.Me.Settings.get([Bonfire.Me.Users, :undiscoverable], nil, current_user: user_etc) !=
          true
    }

    %Actor{
      id: user_etc.id,
      data: data,
      keys: e(user_etc, :character, :actor, :signing_key, nil),
      local: local,
      ap_id: id,
      pointer_id: user_etc.id,
      username: e(user_etc, :character, :username, nil),
      deactivated: false
    }
  end

  def create_remote_actor(%ActivityPub.Actor{} = actor) do
    character_module = character_module(actor.data["type"])

    log("AP - create_remote_actor of type #{actor.data["type"]} with module #{character_module}")

    # username = actor.data["preferredUsername"] <> "@" <> URI.parse(actor.data["id"]).host
    username = actor.username

    with {:error, :not_found} <- get_character_by_username(username),
         {:ok, user_etc} <-
           repo().transact_with(fn ->
             with {:ok, peer} <-
                    Bonfire.Federate.ActivityPub.Instances.get_or_create(actor),
                  {:ok, user_etc} <-
                    maybe_apply_or(
                      character_module,
                      [:create_remote, :create],
                      %{
                        character: %{
                          username: username
                        },
                        profile: %{
                          name: actor.data["name"] || username,
                          summary: actor.data["summary"]
                        },
                        peered: %{
                          peer_id: peer.id,
                          canonical_uri: actor.data["id"]
                        }
                      },
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

      # save remote discoverability flag as a user setting
      if actor.data["discoverable"] in ["false", false, "no"],
        do:
          Bonfire.Me.Settings.put(
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
             maybe_apply(character_module, [:update_remote, :update], [
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

  def create_remote_actor(%ActivityPub.Actor{} = actor), do: create_remote_actor(actor)

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
    do: ActivityPub.Actor.format_remote_actor(object) |> create_remote_actor()

  def character_module(%{__struct__: type}), do: character_module(type)

  def character_module(type) do
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

  def maybe_attach_property_value(:website, "http" <> _ = url)
      when is_binary(url),
      do: property_value(l("Website"), "<a rel=\"me\" href=\"#{url}\">#{url}</a>")

  def maybe_attach_property_value(:website, url) when is_binary(url),
    do: maybe_attach_property_value(:website, "http://" <> url)

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
end
