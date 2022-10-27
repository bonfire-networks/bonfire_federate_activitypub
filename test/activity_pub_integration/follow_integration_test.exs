defmodule Bonfire.Federate.ActivityPub.FollowIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Follows

  import Tesla.Mock

  @remote_instance "https://mocked.local"
  @actor_name "karen@mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: url} ->
        url
        |> String.split("/pub/actors/")
        |> List.last()
        |> ActivityPubWeb.ActorView.actor_json()
        |> json()
    end)

    :ok
  end

  test "follows get queued to federate" do
    me = fake_user!()
    followed = fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(follow)
    assert %{__struct__: ActivityPub.Object} = ap_activity

    Oban.Testing.assert_enqueued(repo(),
      worker: ActivityPub.Workers.PublisherWorker,
      args: %{"op" => "publish", "activity_id" => ap_activity.id}
    )
  end

  test "outgoing follow makes requests" do
    follower = fake_user!()
    {:ok, ap_followed} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    # info(followed)
    {:ok, follow} = Follows.follow(follower, followed)
    info(follow)

    assert {:ok, _follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    assert Bonfire.Social.Follows.requested?(follower, followed)
    refute Bonfire.Social.Follows.following?(follower, followed)
  end

  test "outgoing follow which then gets an Accept works" do
    follower = fake_user!()
    {:ok, ap_follower} = ActivityPub.Adapter.get_actor_by_id(follower.id)

    {:ok, ap_followed} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)

    {:ok, follow} = Follows.follow(follower, followed)

    assert {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    assert Bonfire.Social.Follows.requested?(follower, followed)

    {:ok, accept} =
      ActivityPub.accept(%{
        actor: ap_followed,
        to: [ap_follower.data],
        object: follow_activity.data,
        local: false
      })

    # |> debug
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(accept)

    assert Bonfire.Social.Follows.following?(follower, followed)
  end

  test "incoming follow request works" do
    followed = fake_user!()
    # info(ulid(followed), "followed ID")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    # info(ulid(follower), "follower ID")

    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    # |> debug
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

    assert Bonfire.Social.Follows.requested?(follower, followed)
  end

  test "incoming follow + accept works" do
    followed = fake_user!()
    # info(ulid(followed), "followed ID")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    # info(ulid(follower), "follower ID")

    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    # |> info("requested AP")
    assert {:ok, request} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

    # info(ulid(request), "request ID")

    assert Bonfire.Social.Follows.requested?(follower, followed)

    assert {:ok, follow} = Bonfire.Social.Follows.accept(request, current_user: followed)

    # assert not is_nil(request.accepted_at)
    assert Bonfire.Social.Follows.following?(follower, followed)
  end

  test "incoming follow + ignore works (does not federate rejections)" do
    followed = fake_user!()
    info(ulid(followed), "followed ID")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    info(ulid(follower), "follower ID")

    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, request} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
             |> info("request")

    assert {:ok, request} = Bonfire.Social.Follows.ignore(request, current_user: followed)

    assert not is_nil(request.ignored_at)
  end

  # test "incoming follow works" do # FIXME: need to change the boundaries to allow following without request
  #   followed = fake_user!()
  #   info(ulid(followed), "followed ID")
  #   {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

  #   {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
  #   {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
  #   info(ulid(follower), "follower ID")

  #   {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

  #   assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity) |> debug
  #   assert Bonfire.Social.Follows.following?(follower, followed)
  # end

  test "incoming unfollow works" do
    followed = fake_user!()
    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)
    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    # |> info("requested AP")
    assert {:ok, request} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

    # info(ulid(request), "request ID")

    assert Bonfire.Social.Follows.requested?(follower, followed)

    assert {:ok, follow} = Bonfire.Social.Follows.accept(request, current_user: followed)

    # assert not is_nil(request.accepted_at)
    assert Bonfire.Social.Follows.following?(follower, followed)

    {:ok, unfollow_activity} = ActivityPub.unfollow(ap_follower, ap_followed)

    Bonfire.Federate.ActivityPub.Incoming.receive_activity(unfollow_activity)
    refute Bonfire.Social.Follows.following?(follower, followed)
  end
end
