defmodule Bonfire.Federate.ActivityPub.Dance.FollowRequestTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  # use SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Graph.Follows
  use Mneme

  setup_all tags do
    # Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    [
      local:
        Bonfire.UI.Common.Testing.Helpers.fancy_fake_user!("Local", request_before_follow: true),
      remote:
        Bonfire.UI.Common.Testing.Helpers.fancy_fake_user_on_test_instance(
          request_before_follow: true
        )
    ]
  end

  # https://github.com/bonfire-networks/bonfire-app/issues/537
  # @tag :mneme
  test "remote follow on locked-down profile makes a request, which user can accept, which it turns into a follow, and a post federates back to the follower, and unfollow works",
       context do
    local_follower = context[:local][:user]
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)
    info(follower_ap_id, "follower_ap_id")

    followed_ap_id = context[:remote][:canonical_url]

    info(followed_ap_id, "followed_ap_id")

    Logger.metadata(action: info("init followed_on_local"))
    assert {:ok, followed_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(followed_ap_id)
    # auto_assert Follows.following?(local_follower, followed_on_local)
    # auto_assert Follows.requested?(local_follower, followed_on_local)
    Logger.metadata(action: info("make a (request to) follow"))
    assert {:ok, request} = Follows.follow(local_follower, followed_on_local)
    request_id = uid(request)
    info(request, "the local request")

    assert false == Follows.following?(local_follower, followed_on_local)
    assert true == Follows.requested?(local_follower, followed_on_local)

    # this shouldn't be needed if running Oban :inline
    # Bonfire.Common.Config.get([:bonfire, Oban]) |> info("obannn")
    # Oban.drain_queue(queue: :federator_outgoing)
    # assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(request)

    assert %{__struct__: ActivityPub.Object, pointer_id: ^request_id} =
             Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(request)

    remote_followed = context[:remote][:user]

    post_attrs = %{post_content: %{html_body: "try federated post 67"}}

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init follower_on_remote"))

      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      assert uid(follower_on_remote) != uid(local_follower)
      assert uid(remote_followed) != uid(followed_on_local)

      Logger.metadata(action: info("check request received on remote"))
      assert Follows.requested?(follower_on_remote, remote_followed)
      refute Follows.following?(follower_on_remote, remote_followed)

      Logger.metadata(action: info("accept request"))

      assert {:ok, follow} =
               Follows.accept_from(follower_on_remote, current_user: remote_followed)

      Logger.metadata(action: info("check request is now a follow on remote"))
      assert Follows.following?(follower_on_remote, remote_followed)
      refute Follows.requested?(follower_on_remote, remote_followed)

      # Logger.metadata(action: info("make a post on remote"))

      {:ok, post} =
        Posts.publish(current_user: remote_followed, post_attrs: post_attrs, boundary: "public")
    end)

    Logger.metadata(action: info("check accept was received and local is now following"))
    # FIXME
    assert Follows.following?(local_follower, followed_on_local)
    refute Follows.requested?(local_follower, followed_on_local)

    Logger.metadata(action: info("check that post was federated and is the follower's feed"))

    assert Bonfire.Social.FeedLoader.feed_contains?(:my, post_attrs.post_content.html_body,
             current_user: local_follower
           )

    Logger.metadata(action: info("unfollow"))
    assert {:ok, unfollow} = Follows.unfollow(local_follower, followed_on_local)

    refute Follows.following?(local_follower, followed_on_local) |> info()

    TestInstanceRepo.apply(fn ->
      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      Logger.metadata(action: info("check unfollow received on remote"))

      refute Follows.following?(follower_on_remote, remote_followed)
    end)
  end
end
