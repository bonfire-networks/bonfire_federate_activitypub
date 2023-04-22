defmodule Bonfire.Federate.ActivityPub.Dance.FollowSimpleTest do
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

  test "remote follow on open profile works, and a post federates back to the follower, and unfollow works",
       context do
    local_follower = context[:local][:user]
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)
    info(follower_ap_id, "follower_ap_id")

    followed_ap_id = context[:remote][:canonical_url]

    info(followed_ap_id, "followed_ap_id")

    Logger.metadata(action: info("init followed_on_local"))
    assert {:ok, followed_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(followed_ap_id)

    Logger.metadata(action: info("do the follow"))
    assert {:ok, follow} = Follows.follow(local_follower, followed_on_local)
    fid = ulid(follow)
    # info(request, "the follow")

    assert Follows.following?(local_follower, followed_on_local)

    # this shouldn't be needed if running Oban :inline
    # Bonfire.Common.Config.get([:bonfire, Oban]) |> info("obannn")
    # Oban.drain_queue(queue: :federator_outgoing)
    # assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(request)
    assert %{__struct__: ActivityPub.Object, pointer_id: ^fid} =
             Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(follow)

    remote_followed = context[:remote][:user]

    post_attrs = %{post_content: %{html_body: "try federated post"}}

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init follower_on_remote"))

      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      assert ulid(follower_on_remote) != ulid(local_follower)
      assert ulid(remote_followed) != ulid(followed_on_local)

      Logger.metadata(action: info("check follow worked on remote"))
      assert Follows.following?(follower_on_remote, remote_followed)
      refute Follows.requested?(follower_on_remote, remote_followed)

      Logger.metadata(action: info("make a post on remote"))

      {:ok, post} =
        Posts.publish(current_user: remote_followed, post_attrs: post_attrs, boundary: "public")
    end)

    Logger.metadata(action: info("check that local is following"))
    assert Follows.following?(local_follower, followed_on_local)
    refute Follows.requested?(local_follower, followed_on_local)

    Logger.metadata(action: info("check that post was federated and is the follower's feed"))

    assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: local_follower)

    assert List.first(feed).activity.object.post_content.html_body =~
             post_attrs.post_content.html_body

    Logger.metadata(action: info("unfollow"))
    assert {:ok, unfollow} = Follows.unfollow(local_follower, followed_on_local)

    refute Follows.following?(local_follower, followed_on_local) |> info()

    TestInstanceRepo.apply(fn ->
      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      Logger.metadata(action: info("check unfollow received on remote"))

      refute Follows.following?(follower_on_remote, remote_followed)

      # refute true
    end)
  end



  test "If a remote user is created, and the remote instance does not have a circle, a circle is created and the user is added to it", context do

    # Here we store in a var the total amount of existing circles
    # We will use this to check that a new circle was created
    total_circles = Bonfire.Boundaries.Circles.list_my_with_counts(Bonfire.Boundaries.Fixtures.admin_circle(), exclude_stereotypes: false)

    alice_local = context[:local][:user]
    local_ap_id = Bonfire.Me.Characters.character_url(alice_local)
    {:ok, bob_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])
    {:ok, follow} = Follows.follow(alice_local, bob_remote)
    assert Follows.following?(alice_local, bob_remote)

    updated_circles = Bonfire.Boundaries.Circles.list_my_with_counts(Bonfire.Boundaries.Fixtures.admin_circle(), exclude_stereotypes: false)
    # assert that a new circle is created after the follow, the total amount of circles is increased by 1
    assert length(total_circles) + 1  == updated_circles |> length()

    # assert that the new circle name is the same as the remote instance name
    assert Enum.any?(updated_circles, fn circle -> circle.named.name =~ context[:remote][:canonical_url] end)

    # assert that the user is added to the new circle

  end

  test "If a remote user is created, and the remote instance does have a circle, the user is added to it but no new circles are created", context do

  end

end
