defmodule Bonfire.Federate.ActivityPub.AnnouncementChannelUITest do
  @moduledoc """
  What a person on another instance writes to one of our announcement channels. Only its moderators post in it, so the group does not publish what anyone else writes; it is a message to the moderators, who read it on the group's moderation page (its notifications and its inbox). The model is `group_incoming_flag_ui_test.exs`.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @writer "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @text "A question for the moderators of the channel"

  setup do
    mock(fn
      %{method: :get, url: @writer} -> json(APSimulate.actor_json(@writer))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    # the inbox holds more than the test page size of 2
    Process.put([:bonfire, :default_pagination_limit], 10)

    creator = fake_user!(fake_account!())
    moderator_account = fake_account!()
    moderator = fake_user!(moderator_account)
    reader_account = fake_account!()
    reader = fake_user!(reader_account)

    group = Simulate.fake_group!(creator)
    preset = Bonfire.Boundaries.Presets.group_preset_meta("announcement_channel")

    assert :ok =
             Bonfire.Classify.Boundaries.replace(
               group,
               creator,
               Map.take(preset, [
                 :membership,
                 :visibility,
                 :participation,
                 :default_content_visibility
               ])
             )

    # a promoted moderator, who could not pass on being the group's creator
    {:ok, _} = Categories.add_moderator(creator, group, id(moderator))

    {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

    message = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Create",
      "id" => "#{@writer}/notes/channel/create",
      "actor" => @writer,
      "to" => [group_ap_id, @public],
      "object" => %{
        "id" => "#{@writer}/notes/channel",
        "type" => "Note",
        "attributedTo" => @writer,
        "content" => "<p>#{@text}</p>",
        "to" => [group_ap_id, @public],
        "tag" => [%{"type" => "Mention", "href" => group_ap_id, "name" => "@channel"}]
      }
    }

    {:ok,
     creator: creator,
     group: group,
     message: message,
     moderator_conn: conn(user: moderator, account: moderator_account),
     reader_conn: conn(user: reader, account: reader_account)}
  end

  test "reaches the group's moderators on its moderation page", %{
    moderator_conn: conn,
    group: group,
    message: message
  } do
    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(message)

    conn
    |> visit("/group/#{group.character.username}/settings/moderation")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed] article", text: @text)
  end

  test "is not shown to a reader of the channel, who does see what its moderators post", %{
    reader_conn: conn,
    creator: creator,
    group: group,
    message: message
  } do
    Simulate.fake_post_in_group!(creator, group, "<p>An announcement from the moderators</p>")
    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(message)

    conn
    |> visit("/group/#{group.character.username}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed] article",
      text: "An announcement from the moderators"
    )
    |> refute_has("[data-id=feed] article", text: @text)
  end
end
