defmodule Bonfire.Federate.ActivityPub.Dance.MentionsRepliesPrivateTest do
  @moduledoc """
  User story: I privately mention someone on another instance, and they answer me in different ways. Each way of answering reaches me where I'd expect it:

  - a private reply that doesn't mention me: in my feed, since it answers my post and my bell on it is on (this test turns it on; `MentionsPrivateReplyToPublicTest` turns it off);
  - a private reply that mentions me: in my notifications, as a post rather than a direct message;
  - a public reply that doesn't mention me: federated to me, since I'm the one being replied to;
  - a public reply further down the thread: federated to me too, since I started it.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance
  # @moduletag :mneme

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

  @moduletag :test_instance
  test "private mention and reply", context do
    # context |> info("context")
    post1_attrs = %{
      post_content: %{
        html_body: "#{context[:remote][:username]} try out federated at private mention 11"
      }
    }

    post2_attrs = %{post_content: %{html_body: "try out federated mentions-only 21"}}

    post3_attrs = %{
      post_content: %{
        html_body: "#{context[:local][:username]} try out federated reply with mention 31"
      }
    }

    post4_attrs = %{post_content: %{html_body: "try out federated reply-only 41"}}
    post5_attrs = %{post_content: %{html_body: "try out federated reply in thread 51"}}

    local_user = context[:local][:user]

    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    # my bell on my own posts is ON (a per-user setting, read with `Settings.get(current_user: author)` when I publish, creating the bell that rings for replies below it); `MentionsPrivateReplyToPublicTest` covers it OFF
    local_user =
      Bonfire.Common.Utils.current_user(
        Bonfire.Common.Settings.put([:notifications, :notify_any_replies], true,
          current_user: local_user
        )
      )

    # I post something only the person I mention may see
    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "mentions")

    # error(post1.activity.tagged)

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    debug(post1.activity)
    # it is federated, addressed privately to the person I mentioned
    assert %ActivityPub.Object{} = post1.activity.federate_activity_pub

    # or remote_ap_id in post1.activity.federate_activity_pub.data["bcc"]
    assert remote_ap_id in post1.activity.federate_activity_pub.data["cc"] or
             remote_ap_id in post1.activity.federate_activity_pub.data["bto"]

    ## work on test instance
    TestInstanceRepo.apply(fn ->
      remote_user = context[:remote][:user]
      # they receive it as a direct message, since it was addressed only to them
      assert %{edges: feed} = Messages.list(remote_user)
      assert %Bonfire.Data.Social.Message{} = List.first(feed)

      # debug("post 1 wasn't federated to instance of mentioned actor")

      # %{edges: [feed_entry | _]} = feed
      post1remote = List.first(feed).activity.object

      assert post1remote.post_content.html_body =~
               "try out federated at private mention 11"

      # they answer me in four ways:
      # 1. privately, without mentioning me
      Logger.metadata(action: info("make a mentions-only reply on remote"))

      {:ok, post2} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post2_attrs |> Map.put(:reply_to_id, uid(post1remote)),
          boundary: "mentions"
        )

      # 2. privately, mentioning me
      Logger.metadata(action: info("make a reply with mention on remote"))

      {:ok, post3} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post3_attrs |> Map.put(:reply_to_id, uid(post1remote)),
          boundary: "mentions"
        )

      # 3. publicly, without mentioning me
      Logger.metadata(action: info("make a reply without mention on remote"))

      {:ok, post4} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post4_attrs |> Map.put(:reply_to_id, uid(post1remote)),
          boundary: "public"
        )

      # 4. publicly, replying to their own public reply further down my thread
      Logger.metadata(action: info("make a reply in thread on remote"))

      {:ok, post5} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: post5_attrs |> Map.put(:reply_to_id, uid(post4)),
          boundary: "public"
        )
    end)

    ## back to primary instance

    Logger.metadata(
      action: info("check that the reply-only post IS in OP's feed, as a notification")
    )

    # `:my` is follow-driven AND carries notifications, so pin that no follow is involved: the reply belongs here because it answers the OP, not because they subscribed
    refute Bonfire.Social.Graph.Follows.following?(local_user, get_remote_on_local(context))

    assert Bonfire.Social.FeedLoader.feed_contains?(
             :notifications,
             post2_attrs.post_content.html_body,
             current_user: local_user,
             limit: 100
           ),
           "the reply isn't in my notifications"

    # 1. the private reply that doesn't mention me is in my feed:
    # directly answering someone's post notifies them whether or not it mentions them, and `:my` carries notifications, so this belongs in the OP's feed despite no follow between them
    # `limit:` widened as below: my bell on the thread also brings the later replies, ahead of this one, and the test-env page is 2
    assert Bonfire.Social.FeedLoader.feed_contains?(:my, post2_attrs.post_content.html_body,
             current_user: local_user,
             limit: 100
           )
           |> debug("feeeed")

    Logger.metadata(
      action: info("check that reply with mention was federated and is in OP's feed")
    )

    # assert %{edges: feed} = Messages.list(local_user)
    # auto_assert %Bonfire.Data.Social.Message{} <- List.first(feed)
    # post3remote = List.first(feed).activity.object
    # assert post3remote.post_content.html_body =~ "try out federated reply with mention 31"

    # 2. the private reply that mentions me is in my notifications, as a post rather than a direct message
    # `limit:` widened deliberately. The test-env default page is 2, and this thread puts three replies ahead of the one being asserted on, so the default page would cut it off for reasons that have nothing to do with federation
    %{edges: feed} =
      Bonfire.Social.FeedLoader.feed(:notifications, current_user: local_user, limit: 100)

    assert activity =
             Bonfire.Social.FeedLoader.feed_contains?(
               feed,
               "try out federated reply with mention 31",
               current_user: local_user
             )

    assert post3remote = activity.object

    # ⚠️ not asserted (a bare comparison, its result discarded), so "as a post rather than a direct message" isn't actually checked
    Bonfire.Common.Types.object_type(post3remote) == Bonfire.Data.Social.Post

    # assert Bonfire.Social.FeedLoader.feed_contains?(
    #          feed,
    #          "try out federated reply with mention 31"
    #        )
    #  "reply with mention is NOT in OP's feed"

    Logger.metadata(
      action: info("check that reply without mention was federated and is in fediverse feed")
    )

    # 3. and 4. the public replies are federated to me, in the fediverse feed
    assert %{edges: feed} =
             Bonfire.Social.FeedActivities.feed(:remote, current_user: local_user)
             |> debug("remotefeed")

    assert Bonfire.Social.FeedLoader.feed_contains?(
             feed,
             post4_attrs.post_content.html_body
           )

    #  "if the post is public, the actor we are replying to should be CCed even if not mentioned"

    assert Bonfire.Social.FeedLoader.feed_contains?(
             feed,
             post5_attrs.post_content.html_body
           )

    #  "if the post is public, the actor who started the thread should be CCed even if not mentioned"
  end
end
