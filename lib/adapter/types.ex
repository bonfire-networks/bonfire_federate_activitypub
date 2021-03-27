defmodule Bonfire.Federate.ActivityPub.Types do
  def character_to_actor(character) do
    type =
      case character do
        %Bonfire.Data.Identity.User{} -> "Person"
        # %CommonsPub.Communities.Community{} -> "Group"
        %Bonfire.Data.Identity.Character{} -> "Bonfire:" <> Map.get(character, :facet, "Character")
        _ -> "Bonfire:Character"
      end

    character = Bonfire.Repo.maybe_preload(character, [:character])
    character = Bonfire.Repo.maybe_preload(character, [:profile])

    context = Bonfire.Federate.ActivityPub.Utils.get_context_ap_id(character)

    character =
      character
      |> Map.merge(Map.get(character, :character, %{}))
      |> Map.merge(Map.get(character, :profile, %{}))

    # FIXME: replace with upcoming upload system
    icon_url = CommonsPub.Uploads.remote_url_from_id(Map.get(character, :icon_id))
    image_url = CommonsPub.Uploads.remote_url_from_id(Map.get(character, :image_id))

    id = Bonfire.Federate.ActivityPub.Utils.generate_actor_url(character)

    username = Bonfire.Federate.ActivityPub.Utils.get_actor_username(character)

    #IO.inspect(character)

    data =
      %{
        "type" => type,
        "id" => id,
        "inbox" => "#{id}/inbox",
        "outbox" => "#{id}/outbox",
        "followers" => "#{id}/followers",
        "following" => "#{id}/following",
        "preferredUsername" => username,
        "name" => Map.get(character, :name),
        "summary" => Map.get(character, :summary)
      }
      |> Bonfire.Common.Utils.maybe_put(
        "icon",
        Bonfire.Federate.ActivityPub.Utils.maybe_create_image_object(icon_url)
      )
      |> Bonfire.Common.Utils.maybe_put(
        "image",
        Bonfire.Federate.ActivityPub.Utils.maybe_create_image_object(image_url)
      )
      |> Bonfire.Common.Utils.maybe_put(
        "attributedTo",
        Bonfire.Federate.ActivityPub.Utils.get_different_creator_ap_id(character)
      )
      |> Bonfire.Common.Utils.maybe_put("context", context)
      |> Bonfire.Common.Utils.maybe_put("collections", get_and_format_collections_for_actor(character))
      |> Bonfire.Common.Utils.maybe_put("resources", get_and_format_resources_for_actor(character))

    %ActivityPub.Actor{
      id: character.id,
      data: data,
      keys: Map.get(Map.get(character, :character, character), :signing_key),
      local: Bonfire.Federate.ActivityPub.Utils.check_local(character),
      ap_id: id,
      pointer_id: character.id,
      username: username,
      deactivated: false
    }
  end


  # TODO
  def get_and_format_collections_for_actor(_actor) do
    []
  end

  # TODO
  def get_and_format_resources_for_actor(_actor) do
    []
  end
end
