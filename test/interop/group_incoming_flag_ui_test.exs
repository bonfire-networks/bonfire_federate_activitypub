defmodule Bonfire.Federate.ActivityPub.GroupIncomingFlagUITest do
  @moduledoc """
  A report from another instance about a post in one of OUR groups. Lemmy sends it as the reporter, addressed to the group with the reason in `summary` (`lemmy/mod_flag_page.json`'s shape), and it has to reach the group's moderators: on the group's moderation page, where they find everything waiting on them, and in their own notifications. The reporter can withdraw it with an `Undo`.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  alias Bonfire.Classify.Simulate
  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @reporter "https://mocked.local/users/karen"
  @post_text "A post someone elsewhere reported"

  setup do
    mock(fn
      %{method: :get, url: @reporter} -> json(APSimulate.actor_json(@reporter))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    # the inbox holds more than the test page size of 2
    Process.put([:bonfire, :default_pagination_limit], 10)

    creator = fake_user!(fake_account!())
    moderator_account = fake_account!()
    moderator = fake_user!(moderator_account)
    member = fake_user!(fake_account!())

    group =
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    # a promoted moderator, who could not pass on being the group's creator
    {:ok, _} = Categories.add_moderator(creator, group, id(moderator))
    {:ok, _} = Categories.join_and_follow_group(member, group)
    post = Simulate.fake_post_in_group!(member, group, "<p>#{@post_text}</p>")

    {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group)
    {:ok, %{data: %{"id" => post_ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

    flag = %{
      "type" => "Flag",
      "id" => "#{@reporter}/flags/group-post",
      "actor" => @reporter,
      "to" => [group_ap_id],
      "audience" => group_ap_id,
      "object" => post_ap_id,
      "summary" => "reported from afar"
    }

    {:ok,
     group: group,
     post: post,
     flag: flag,
     moderator: moderator,
     conn: conn(user: moderator, account: moderator_account)}
  end

  test "reaches the group's moderators, on its moderation page and in their notifications", %{
    conn: conn,
    group: group,
    flag: flag
  } do
    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(flag)

    conn
    |> visit("/group/#{group.character.username}/settings/moderation")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed] article", text: @post_text)

    conn
    |> visit("/notifications")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed] article", text: @post_text)
  end

  # `Undo` is how a report is withdrawn; a `Delete` of it says the same, and is read the same way
  for type <- ["Undo", "Delete"] do
    test "the reporter can withdraw it, with #{type}", %{post: post, flag: flag} do
      type = unquote(type)
      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(flag)
      {:ok, reporter} = Bonfire.Me.Users.by_ap_id(@reporter)
      assert Bonfire.Social.Flags.flagged?(reporter, post), "control: the report was received"

      withdrawal = %{
        "type" => type,
        "id" => "#{@reporter}/flags/group-post/#{String.downcase(type)}",
        "actor" => @reporter,
        "to" => flag["to"],
        "object" => flag
      }

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(withdrawal)
      refute Bonfire.Social.Flags.flagged?(reporter, post), "the #{type} withdraws the report"
    end
  end
end
