# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Utils do
  use Bonfire.Common.Utils
  import Bonfire.Federate.ActivityPub
  alias ActivityPub.Actor
  alias Bonfire.Social.Threads
  require Logger
  import Where

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  def public_uri(), do: @public_uri

  def log(l) do
    if(Bonfire.Common.Config.get(:log_federation)) do
      Logger.info(inspect l)
    end
  end

  def ap_base_url() do
    Bonfire.Federate.ActivityPub.Adapter.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
  end

  def is_local?(%{is_local: true}) do
    # publish if explicitly known to be local
    true
  end

  def is_local?(%{character: %{peered: nil}}) do
    # publish local characters
    true
  end

  def is_local?(%{peered: nil}) do
    # publish local characters
    true
  end

  def is_local?(%{created: %{peered: nil}}) do
    # publish if author (using created mixin) is local
    true
  end

  def is_local?(%{creator: %{peered: nil}}) do
    # publish if author (in VF) is local
    true
  end

  def is_local?(id) when is_binary(id), do: Bonfire.Common.Pointers.one(id, skip_boundary_check: true) |> repo().maybe_preload([:peered, character: [:peered], created: [:peered]]) |> is_local?()

  def is_local?(context), do: false

  def get_actor_username(%{preferred_username: u}) when is_binary(u),
    do: u

  def get_actor_username(%{username: u}) when is_binary(u),
    do: u

  def get_actor_username(%{character: %Ecto.Association.NotLoaded{}} = obj) do
    get_actor_username(Bonfire.Repo.maybe_preload(obj, :character))
  end

  def get_actor_username(%{character: c}),
    do: get_actor_username(c)

  def get_actor_username(u) when is_binary(u),
    do: u

  def get_actor_username(_),
    do: nil

  def generate_actor_url(u) when is_binary(u) and u != "",
    do: ap_base_url() <> "/actors/" <> u

  def generate_actor_url(obj) do
    with nil <- get_actor_username(obj) do
      generate_object_ap_id(obj)
    else
      username ->
        generate_actor_url(username)
    end
  end

  @doc "Get canonical URL if set, or generate one"

  # def get_actor_canonical_url(%{actor: actor}) do
  #   get_actor_canonical_url(actor)
  # end

  def get_actor_canonical_url(%{canonical_url: canonical_url}) when not is_nil(canonical_url) do
    canonical_url
  end

  def get_actor_canonical_url(%{character: %{canonical_url: canonical_url}})
      when not is_nil(canonical_url) do
    canonical_url
  end

  def get_actor_canonical_url(%{character: %Ecto.Association.NotLoaded{}} = obj) do
    get_actor_canonical_url(Map.get(Bonfire.Repo.maybe_preload(obj, :character), :character))
  end

  def get_actor_canonical_url(actor) do
    generate_actor_url(actor)
  end

  @doc "Generate canonical URL for local object"
  def generate_object_ap_id(%{id: id}) do
    generate_object_ap_id(id)
  end

  def generate_object_ap_id(url = "http://" <> _) do
    url
  end

  def generate_object_ap_id(url = "https://" <> _) do
    url
  end

  def generate_object_ap_id(id) when is_binary(id) or is_number(id) do
    "#{ap_base_url()}/objects/#{id}"
  end

  def generate_object_ap_id(_) do
    nil
  end

  @doc "Get canonical URL for object"
  def get_object_canonical_url(%{canonical_url: canonical_url}) when not is_nil(canonical_url) do
    canonical_url
  end

  def get_object_canonical_url(object) do
    generate_object_ap_id(object)
  end

  def get_character_by_username("@"<>username), do: get_character_by_username(username)

  def get_character_by_username(username) when is_binary(username) do
    with {:ok, character} <- Bonfire.Me.Characters.by_username(username) do
      get_character_by_id(character.id) # FIXME? this results in two more queries
    else e ->
      {:error, :not_found}
    end
  end

  def get_character_by_username(%{} = character), do: {:ok, character}


  def get_character_by_id(id) when is_binary(id) do
    pointer_id = ulid(id)
    if pointer_id do
      with %{} = user_etc <- Bonfire.Common.Pointers.get(pointer_id, skip_boundary_check: true) do
      {:ok, user_etc}
      end
    end
  end


  # def get_character_by_ap_id(%{"preferredUsername" => username}) when is_binary(username) do
  #   get_character_by_username(username) |> dump("preferredUsername: #{username}")
  # end

  def get_character_by_ap_id(%{username: username}) when is_binary(username) do
    get_character_by_username(username) |> dump("username: #{username}")
  end

  def get_character_by_ap_id(%{data: data}) do
    get_character_by_ap_id(data) |> dump("data")
  end

  def get_character_by_ap_id(%{"id" => ap_id}) when is_binary(ap_id) do
    get_character_by_ap_id(ap_id) |> dump("id: #{ap_id}")
  end

  def get_character_by_ap_id(ap_id) when is_binary(ap_id) do
    dump("ap_id: #{ap_id}")
    # FIXME: this should not query the AP db
    # query Character.Peered instead? but what about if we're requesting a remote actor which isn't cached yet?
    with {:ok, actor} <- ActivityPub.Actor.get_or_fetch_by_ap_id(ap_id) do
      get_character_by_ap_id(actor)
    end
  end

  def get_character_by_ap_id(%{} = character), do: {:ok, character}

  def get_character_by_ap_id(other) do
    error("get_character_by_ap_id: dunno how to get character for #{inspect other}")
    {:error, :not_found}
  end


  def get_character_by_ap_id!(ap_id) do
    with {:ok, character} <- get_character_by_ap_id(ap_id) do
      character
    else
      %{} = character -> character
      _ -> nil
    end
  end

  def get_by_url_ap_id_or_username("@"<>username), do: get_or_fetch_and_create_by_userame(username)
  def get_by_url_ap_id_or_username("http:"<>_ = url), do: get_or_fetch_and_create_by_uri(url)
  def get_by_url_ap_id_or_username("https:"<>_ = url), do: get_or_fetch_and_create_by_uri(url)
  def get_by_url_ap_id_or_username(string) when is_binary(string) do
    if validate_url(string) do
      get_or_fetch_and_create_by_uri(string)
    else
      get_or_fetch_and_create_by_userame(string)
    end
  end

  defp get_or_fetch_and_create_by_userame(q) when is_binary(q) do
    log("AP - get_or_fetch_and_create_by_userame: "<> q)
    ActivityPub.Actor.get_or_fetch_by_username(q) ~> return_character()
  end

  def get_or_fetch_and_create_by_uri(q) when is_binary(q) do
    log("AP - get_or_fetch_and_create_by_uri: "<> q)
    ActivityPub.Fetcher.get_or_fetch_and_create(q) ~> return_character()
  end

  defp return_character(fetched) do
    dump(fetched)
    case fetched do
     %{pointer_id: id} when is_binary(id) ->
        id
        |> dump()
        |> Bonfire.Common.Pointers.get(skip_boundary_check: true)
        |> dump # TODO: privacy
     %{} -> get_character_by_ap_id(fetched) |> dump
    end
  end

  def validate_url(str) do
    uri = URI.parse(str)
    case uri do
      %URI{scheme: nil} -> false
      %URI{host: nil} -> false
      uri -> true
    end
  end

  def get_or_fetch_actor_by_ap_id!(ap_id) when is_binary(ap_id) do
    log("AP - get_or_fetch_actor_by_ap_id! : "<> ap_id)
    with {:ok, actor} <- ActivityPub.Actor.get_or_fetch_by_ap_id(ap_id) do
      actor
    else
      _ -> nil
    end
  end

  def get_cached_actor_by_local_id!(ap_id) when is_binary(ap_id) do
    log("AP - get_cached_actor_by_local_id! : "<> ap_id)
    with {:ok, actor} <- ActivityPub.Actor.get_cached_by_local_id(ap_id) do
      actor
    else
      _ -> nil
    end
  end

  def get_object_or_actor_by_ap_id!(ap_id) when is_binary(ap_id) do
    log("AP - get_object_or_actor_by_ap_id! : "<> ap_id)
    # FIXME?
    ActivityPub.Object.get_cached_by_ap_id(ap_id) ||
      get_or_fetch_actor_by_ap_id!(ap_id) || ap_id
  end

  def get_object_or_actor_by_ap_id!(ap_id) do
    ap_id
  end


  def get_creator_ap_id(%{creator_id: creator_id}) when not is_nil(creator_id) do
    log("AP - get_creator_ap_id! : "<> creator_id)
    with {:ok, %{ap_id: ap_id}} <- ActivityPub.Actor.get_cached_by_local_id(creator_id) do
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

  def get_context_ap_id(%{context_id: context_id}) when not is_nil(context_id) do
    log("AP - get_context_ap_id! : "<> context_id)
    with {:ok, %{ap_id: ap_id}} <- ActivityPub.Actor.get_cached_by_local_id(context_id) do
      ap_id
    else
      _ -> nil
    end
  end

  def get_context_ap_id(_), do: nil


  def character_to_actor(character) do
    with %ActivityPub.Actor{} = actor <- Bonfire.Common.ContextModules.maybe_apply(character, :format_actor, character) do
      {:ok, actor} # TODO: use federation_module instead of context_module?
    else _ ->
      format_actor(character)
    end
  end

  def format_actor(%{} = user_etc, type \\ "Person") do
    user_etc = Bonfire.Repo.preload(user_etc, [profile: [:image, :icon], character: [:actor], peered: []]) #|> IO.inspect()
    ap_base_path = Bonfire.Common.Config.get(:ap_base_path, "/pub")
    id = Bonfire.Common.URIs.base_url() <> ap_base_path <> "/actors/#{user_etc.character.username}"

    # icon = maybe_format_image_object_from_path(Bonfire.Files.IconUploader.remote_url(user_etc.profile.icon))
    # image = maybe_format_image_object_from_path(Bonfire.Files.ImageUploader.remote_url(user_etc.profile.image))

    icon = maybe_format_image_object_from_path(avatar_url(user_etc))
    image = maybe_format_image_object_from_path(image_url(user_etc))

    local = if user_etc.peered, do: false, else: true

    data = %{
      "type" => type,
      "id" => id,
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox",
      "followers" => "#{id}/followers",
      "following" => "#{id}/following",
      "preferredUsername" => e(user_etc, :character, :username, nil),
      "name" => e(user_etc, :profile, :name, nil),
      "summary" => e(user_etc, :profile, :summary, nil),
      "icon" => icon,
      "image" => image,
      "attachment" => maybe_attach_property_value(l("Website"), e(user_etc, :profile, :website, nil)),
      "endpoints" => %{
        "sharedInbox" => Bonfire.Common.URIs.base_url() <> ap_base_path <> "/shared_inbox"
      }
    }

    %Actor{
      id: user_etc.id,
      data: data,
      keys: Bonfire.Common.Utils.maybe_get(user_etc.character.actor, :signing_key),
      local: local,
      ap_id: id,
      pointer_id: user_etc.id,
      username: user_etc.character.username,
      deactivated: false
    }
  end

  def determine_recipients(actor, comment) do
    determine_recipients(actor, comment, [public_uri()], [actor.data["followers"]])
  end

  def determine_recipients(actor, comment, parent) do
    if(is_map(parent) and Map.has_key?(parent, :id)) do
      case ActivityPub.Actor.get_cached_by_local_id(parent.id) do
        {:ok, parent_actor} ->
          determine_recipients(actor, comment, [parent_actor.ap_id, public_uri()], [
            actor.data["followers"]
          ])

        _ ->
          determine_recipients(actor, comment)
      end
    else
      determine_recipients(actor, comment)
    end
  end

  def determine_recipients(actor, comment, to, cc) do
    # this doesn't feel very robust
    to =
      unless is_nil(get_in_reply_to(comment)) do
        participants =
          Threads.list_comments_in_thread(comment.thread) # FIXME: replace with correct call
          |> Enum.map(fn comment -> comment.creator_id end)
          |> Enum.map(&ActivityPub.Actor.get_by_local_id!/1)
          |> Enum.filter(fn actor -> actor end)
          |> Enum.map(fn actor -> actor.ap_id end)

        (participants ++ to)
        |> Enum.dedup()
        |> List.delete(Map.get(Actor.get_by_local_id!(actor.id), :ap_id))
      else
        to
      end

    {to, cc}
  end

  def get_in_reply_to(comment) do
    reply_to_id = Map.get(comment, :reply_to_id)

    if reply_to_id do
      case ActivityPub.Object.get_cached_by_pointer_id(reply_to_id) do
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
    case ActivityPub.Object.get_cached_by_pointer_id(id) do
      nil ->
        case ActivityPub.Actor.get_cached_by_local_id(id) do
          {:ok, actor} -> actor.ap_id
          {:error, e} -> {:error, e}
        end

      object ->
        object.data["id"]
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

  def get_object(object) do
    case ActivityPub.Object.get_cached_by_pointer_id(object.id) do
      nil ->
        case ActivityPub.Actor.get_cached_by_local_id(object.id) do
          {:ok, actor} -> actor
          {:error, e} -> {:error, e}
        end

      object ->
        object
    end
  end

  def get_pointer_id_by_ap_id(ap_id) do
    case ActivityPub.Object.get_cached_by_ap_id(ap_id) do
      nil ->
        # Might be a local actor
        with {:ok, actor} <- ActivityPub.Actor.get_cached_by_ap_id(ap_id) do
          actor.pointer_id
        else
          _ -> nil
        end

      %ActivityPub.Object{} = object ->
        object.pointer_id
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

  def maybe_create_image_object(nil, _actor), do: nil

  def maybe_create_image_object(url, actor) do
    maybe_upload(Bonfire.Files.ImageUploader, url, actor)
  end

  def maybe_create_image_object(nil), do: nil

  def maybe_create_image_object(url) do
    %{
      "type" => "Image",
      "url" => url
    }
  end

  def maybe_format_image_object_from_path("http"<>_ = url) do
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

  def maybe_attach_property_value(name, "http"<>_=url) when is_binary(url) do
    [
      %{
        "name" => name,
        "type" => "PropertyValue",
        "value" =>
          "<a rel=\"me\" href=\"#{url}\">#{url}</a>"
      }
    ]
  end
  def maybe_attach_property_value(name, url) when is_binary(url), do: maybe_attach_property_value(name, "http://"<>url)
  def maybe_attach_property_value(_, _), do: nil


  def maybe_create_icon_object(nil, _actor), do: nil

  def maybe_create_icon_object(url, actor) do
    maybe_upload(Bonfire.Files.IconUploader, url, actor)
  end

  defp maybe_upload(adapter, url, actor) do
    debug(url)
    with {:ok, %{id: id}} <- Bonfire.Files.upload(Bonfire.Files.IconUploader, actor, url, %{}) do
      id
    else _ ->
      nil
    end
  end

end
