defmodule Bonfire.Federate.ActivityPub.Dance.MentionsRepliesPrivateTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance
  @moduletag :mneme

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
  test "private mention and reply", context do
    # context |> info("context")
    post1_attrs = %{
      post_content: %{
        html_body: "#{context[:remote][:username]} try out federated at private mention 10"
      }
    }

    post2_attrs = %{post_content: %{html_body: "try out federated mentions-only"}}

    post3_attrs = %{
      post_content: %{
        html_body: "#{context[:local][:username]} try out federated reply with mention"
      }
    }

    post4_attrs = %{post_content: %{html_body: "try out federated reply-only"}}
    post5_attrs = %{post_content: %{html_body: "try out federated reply in thread"}}

    local_user = context[:local][:user]

    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "mentions")

    # error(post1.activity.tagged)

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    debug(post1.activity)
    auto_assert %ActivityPub.Object{} <- post1.activity.federate_activity_pub

    auto_assert true <-
                  List.first(post1.activity.federate_activity_pub.data["cc"]) == remote_ap_id

    ## work on test instance
    TestInstanceRepo.apply(fn ->
      remote_user = context[:remote][:user]
      assert %{edges: feed} = Messages.list(remote_user)
      auto_assert %Bonfire.Data.Social.Message{} <- List.first(feed)

      # feed = Bonfire.Social.FeedActivities.feed(:inbox, current_user: remote_user)
      # auto_assert true <- match?(%{edges: [feed_entry | _]}, feed)
      # debug("post 1 wasn't federated to instance of mentioned actor")

      # %{edges: [feed_entry | _]} = feed
      post1remote = List.first(feed).activity.object

      auto_assert true <-
                    post1remote.post_content.html_body =~
                      "try out federated at private mention 10"

      Logger.metadata(action: info("make a mentions-only reply on remote"))

      {:ok, post2} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post2_attrs |> Map.put(:reply_to_id, uid(post1remote)),
          boundary: "mentions"
        )

      Logger.metadata(action: info("make a reply with mention on remote"))

      {:ok, post3} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post3_attrs |> Map.put(:reply_to_id, uid(post1remote)),
          boundary: "mentions"
        )

      Logger.metadata(action: info("make a reply without mention on remote"))

      {:ok, post4} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post4_attrs |> Map.put(:reply_to_id, uid(post1remote)),
          boundary: "public"
        )

      Logger.metadata(action: info("make a reply in thread on remote"))

      {:ok, post5} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post5_attrs |> Map.put(:reply_to_id, uid(post4)),
          boundary: "public"
        )
    end)

    ## back to primary instance

    Logger.metadata(action: info("check that reply-only is NOT in OP's feed"))

    assert %{edges: feed} =
             Bonfire.Social.FeedActivities.feed(:my, current_user: local_user) |> debug("feeeed")

    Enum.each(
      feed,
      &refute(&1.activity.object.post_content.html_body =~ post2_attrs.post_content.html_body)
    )

    Logger.metadata(
      action: info("check that reply with mention was federated and is in OP's feed")
    )

    assert %{edges: feed} = Messages.list(local_user)
    auto_assert %Bonfire.Data.Social.Message{} <- List.first(feed)
    post2remote = List.first(feed).activity.object

    assert post2remote.post_content.html_body =~ "try out federated reply with mention"

    # assert Bonfire.Social.FeedActivities.feed_contains?(
    #          feed,
    #          "try out federated reply with mention"
    #        )
    #  "reply with mention is NOT in OP's feed"

    Logger.metadata(
      action: info("check that reply without mention was federated and is in fediverse feed")
    )

    assert %{edges: feed} =
             Bonfire.Social.FeedActivities.feed(:fediverse, current_user: local_user)
             |> debug("remotefeed")

    assert Bonfire.Social.FeedActivities.feed_contains?(
             feed,
             post4_attrs.post_content.html_body
           )

    #  "if the post is public, the actor we are replying to should be CCed even if not mentioned"

    assert Bonfire.Social.FeedActivities.feed_contains?(
             feed,
             post5_attrs.post_content.html_body
           )

    #  "if the post is public, the actor who started the thread should be CCed even if not mentioned"
  end
end
