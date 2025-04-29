defmodule Bonfire.Federate.ActivityPub.Dance.MentionsPrivateReplyToPublicTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance
  # @moduletag :mneme
  # use Mneme

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.{Circles, Acls, Grants}
  alias Bonfire.Messages

  @moduletag :test_instance
  test "private reply to public post create a Post rather than a DM", context do
    # context |> info("context")
    post1_text = "try out federated at public mention 100"

    post1_attrs = %{
      post_content: %{
        html_body: "#{context[:remote][:username]} #{post1_text}"
      }
    }

    post2_attrs = %{post_content: %{html_body: "try out federated mentions-only"}}

    post3_text = "try out federated reply with mention 200"

    post3_attrs = %{
      post_content: %{
        html_body: "#{context[:local][:username]} #{post3_text}"
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
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "public")

    # error(post1.activity.tagged)

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    debug(post1.activity)
    assert %ActivityPub.Object{} = post1.activity.federate_activity_pub

    assert true =
             List.first(post1.activity.federate_activity_pub.data["cc"]) == remote_ap_id

    ## work on test instance
    TestInstanceRepo.apply(fn ->
      remote_user = context[:remote][:user]

      %{edges: feed} = Bonfire.Social.FeedLoader.feed(:notifications, current_user: remote_user)

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(feed, post1_text,
                 current_user: local_user
               )

      assert post1remote = activity.object
      Bonfire.Common.Types.object_type(post1remote) == Bonfire.Data.Social.Post

      # debug("post 1 wasn't federated to instance of mentioned actor")

      # %{edges: [feed_entry | _]} = feed

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
          boundary: "mentions"
        )

      Logger.metadata(action: info("make a reply in thread on remote"))

      {:ok, post5} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post5_attrs |> Map.put(:reply_to_id, uid(post4)),
          boundary: "mentions"
        )
    end)

    ## back to primary instance

    Logger.metadata(action: info("check that reply-only is NOT in OP's feed"))

    %{edges: feed} = Bonfire.Social.FeedLoader.feed(:notifications, current_user: local_user)

    refute Bonfire.Social.FeedLoader.feed_contains?(feed, post2_attrs.post_content.html_body,
             current_user: local_user
           )

    Logger.metadata(
      action: info("check that reply with mention was federated and is in OP's feed")
    )

    assert activity =
             Bonfire.Social.FeedLoader.feed_contains?(feed, post3_text, current_user: local_user)

    assert post3remote = activity.object

    Bonfire.Common.Types.object_type(post3remote) == Bonfire.Data.Social.Post

    # assert Bonfire.Social.FeedLoader.feed_contains?(
    #          feed,
    #          "try out federated reply with mention"
    #        )
    #  "reply with mention is NOT in OP's feed"

    Logger.metadata(
      action: info("ccheck that replies without mention were federated and are in fediverse feed")
    )

    assert %{edges: feed} =
             Bonfire.Social.FeedActivities.feed(:remote, current_user: local_user)

    #  |> debug("remotefeed")

    assert activity =
             Bonfire.Social.FeedLoader.feed_contains?(
               feed,
               post4_attrs.post_content.html_body
             )

    assert post4remote = activity.object

    Bonfire.Common.Types.object_type(post4remote) == Bonfire.Data.Social.Post

    #  "if the post is public, the actor we are replying to should be CCed even if not mentioned"

    assert activity =
             Bonfire.Social.FeedLoader.feed_contains?(
               feed,
               post5_attrs.post_content.html_body
             )

    assert post5remote = activity.object

    Bonfire.Common.Types.object_type(post5remote) == Bonfire.Data.Social.Post

    #  "if the post is public, the actor who started the thread should be CCed even if not mentioned"

    Logger.metadata(
      action: info("check that replies were federated but are not visible to others")
    )

    assert %{edges: feed} =
             Bonfire.Social.FeedActivities.feed(:remote, current_user: fake_user!())

    #  |> debug("remotefeed")

    refute Bonfire.Social.FeedLoader.feed_contains?(feed, post2_attrs.post_content.html_body)

    refute Bonfire.Social.FeedLoader.feed_contains?(feed, post3_text)

    refute Bonfire.Social.FeedLoader.feed_contains?(
             feed,
             post4_attrs.post_content.html_body
           )

    refute Bonfire.Social.FeedLoader.feed_contains?(
             feed,
             post5_attrs.post_content.html_body
           )
  end
end
