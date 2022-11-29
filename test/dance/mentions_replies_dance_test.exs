defmodule Bonfire.Federate.ActivityPub.Dance.MentionsRepliesTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  @tag :test_instance
  test "mention", context do
    # context |> info("context")

    local_user = context[:local][:user]
    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    remote_user = context[:remote][:user]

    post1_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} test federated at mention"}
    }

    post2_attrs = %{post_content: %{html_body: "test federated reply only"}}

    post3_attrs = %{
      post_content: %{
        html_body: "#{context[:local][:username]} test federated reply with mention"
      }
    }

    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "public")

    TestInstanceRepo.apply(fn ->
      assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: remote_user)
      post1remote = List.first(feed).activity.object
      assert post1remote.post_content.html_body =~ "test federated at mention"

      Logger.metadata(action: info("make a reply on remote"))

      {:ok, post2} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post2_attrs |> Map.put(:reply_to_id, ulid(post1remote)),
          boundary: "public"
        )

      Logger.metadata(action: info("make a reply with mention on remote"))

      {:ok, post3} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post3_attrs |> Map.put(:reply_to_id, ulid(post1remote)),
          boundary: "public"
        )
    end)

    Logger.metadata(action: info("check that reply-only is NOT in OP's feed"))

    assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: local_user)

    Enum.each(
      feed,
      &refute(&1.activity.object.post_content.html_body =~ post2_attrs.post_content.html_body)
    )

    Logger.metadata(
      action: info("check that reply with mention was federated and is in OP's feed")
    )

    post3remote = List.first(feed).activity.object
    assert post3remote.post_content.html_body =~ "test federated reply with mention"
  end
end