defmodule Bonfire.Federate.ActivityPub.Dance.MentionsRepliesPublicTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.{Circles, Acls, Grants}
  alias Bonfire.Messages
  use Mneme

  @tag :test_instance
  test "public mention and reply", context do
    # context |> info("context")

    local_user = context[:local][:user]
    # |> info("local_user")

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    msg11 = "try out federated public at mention 11"

    post11_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} #{msg11}"}
    }

    post27_attrs = %{post_content: %{html_body: "try out federated public reply 27"}}

    msg31 = "try out federated reply with mention 31"

    post31_attrs = %{
      post_content: %{
        html_body: "#{context[:local][:username]} #{msg31}"
      }
    }

    post44_attrs = %{post_content: %{html_body: "try out federated reply-only 44"}}
    post55_attrs = %{post_content: %{html_body: "try out federated reply 55 in thread"}}

    {:ok, post11} =
      Posts.publish(current_user: local_user, post_attrs: post11_attrs, boundary: "public")

    # error(post11.activity.tagged)

    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    debug(post11.activity)
    assert post11.activity.federate_activity_pub
    assert List.first(post11.activity.federate_activity_pub.data["cc"]) == remote_ap_id

    ## work on test instance
    TestInstanceRepo.apply(fn ->
      remote_user = context[:remote][:user]

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(:my, msg11, current_user: remote_user)

      post11remote = activity.object

      Logger.metadata(action: info("make a reply on remote"))

      {:ok, post27} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post27_attrs |> Map.put(:reply_to_id, uid(post11remote)),
          boundary: "public"
        )

      Logger.metadata(action: info("make a reply with mention on remote"))

      {:ok, post31} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post31_attrs |> Map.put(:reply_to_id, uid(post11remote)),
          boundary: "public"
        )

      Logger.metadata(action: info("make a reply without mention on remote"))

      {:ok, post44} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post44_attrs |> Map.put(:reply_to_id, uid(post11remote)),
          boundary: "public"
        )

      Logger.metadata(action: info("make a reply in thread on remote"))

      {:ok, post55} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post55_attrs |> Map.put(:reply_to_id, uid(post44)),
          boundary: "public"
        )
    end)

    ## back to primary instance
    Logger.metadata(action: info("load local feeds"))

    assert %{edges: instance_feed} =
             Bonfire.Social.FeedActivities.feed(:explore, current_user: local_user, limit: 10)

    assert %{edges: notifications} =
             Bonfire.Social.FeedActivities.feed(:notifications,
               current_user: local_user,
               limit: 20
             )

    Logger.metadata(
      action: info("check that reply 31 with mention was federated and is in instance feed")
    )

    assert Bonfire.Social.FeedLoader.feed_contains?(
             instance_feed,
             msg31
           )

    Logger.metadata(
      action:
        info("check that reply 44 and 55 without mention are federated and in instance feed")
    )

    assert Bonfire.Social.FeedLoader.feed_contains?(
             instance_feed,
             post44_attrs.post_content.html_body
           )

    assert Bonfire.Social.FeedLoader.feed_contains?(
             instance_feed,
             post55_attrs.post_content.html_body
           )

    Logger.metadata(action: info("check that reply-only 27 is NOT in OP's notifications"))

    refute Bonfire.Social.FeedLoader.feed_contains?(
             notifications,
             post27_attrs.post_content.html_body
           )

    # FIXME
    Logger.metadata(
      action: info("check that reply 31 with mention was federated and is in OP's notifications")
    )

    assert Bonfire.Social.FeedLoader.feed_contains?(
             notifications,
             msg31
           )
  end
end
