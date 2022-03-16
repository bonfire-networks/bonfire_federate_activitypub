defmodule Bonfire.Federate.ActivityPub.FollowIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Follows

  import Tesla.Mock

  @remote_instance "https://kawen.space"
  @actor_name "karen@kawen.space"
  @remote_actor @remote_instance<>"/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    :ok
  end

  test "outgoing follow makes requests" do
    follower = fake_user!()
    {:ok, ap_followed} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    {:ok, follow} = Follows.follow(follower, followed)

    assert {:ok, _follow_activity} = Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{args: %{"op" => "create", "context_id" => follow.id}})

    assert Bonfire.Social.Follows.requested?(follower, followed)
    refute Bonfire.Social.Follows.following?(follower, followed)
  end

  test "outgoing follow which then gets an Accept works" do
    follower = fake_user!()
    {:ok, ap_follower} = ActivityPub.Adapter.get_actor_by_id(follower.id)

    {:ok, ap_followed} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)

    {:ok, follow} = Follows.follow(follower, followed)

    assert {:ok, follow_activity} = Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{args: %{"op" => "create", "context_id" => follow.id}})

    assert Bonfire.Social.Follows.requested?(follower, followed)

    {:ok, accept} = ActivityPub.accept(%{
      actor: ap_followed,
      to: [ap_follower.data],
      object: follow_activity.data,
      local: false
    })
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(accept) #|> dump

    assert Bonfire.Social.Follows.following?(follower, followed)
  end

  test "incoming follow request works" do
    followed = fake_user!()
    # dump(ulid(followed), "followed ID")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    # dump(ulid(follower), "follower ID")

    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity) #|> dump
    assert Bonfire.Social.Follows.requested?(follower, followed)
  end

  test "incoming follow + accept works" do
    followed = fake_user!()
    # dump(ulid(followed), "followed ID")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    # dump(ulid(follower), "follower ID")

    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, request} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity) #|> dump("requested AP")
    # dump(ulid(request), "request ID")

    assert Bonfire.Social.Follows.requested?(follower, followed)

    assert {:ok, follow} = Bonfire.Social.Follows.accept(request, current_user: followed)
    # assert not is_nil(request.accepted_at)
    assert Bonfire.Social.Follows.following?(follower, followed)
  end

  test "incoming follow + ignore works (does not federate rejections)" do
    followed = fake_user!()
    dump(ulid(followed), "followed ID")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    dump(ulid(follower), "follower ID")

    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, request} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity) |> dump("request")

    assert {:ok, request} = Bonfire.Social.Follows.ignore(request, current_user: followed)
    assert not is_nil(request.ignored_at)
  end


  # test "incoming follow works" do # FIXME: need to change the boundaries to allow following without request
  #   followed = fake_user!()
  #   dump(ulid(followed), "followed ID")
  #   {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)

  #   {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
  #   {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
  #   dump(ulid(follower), "follower ID")

  #   {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

  #   assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity) |> dump
  #   assert Bonfire.Social.Follows.following?(follower, followed)
  # end

  test "incoming unfollow works" do
    followed = fake_user!()
    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)
    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, request} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity) #|> dump("requested AP")
    # dump(ulid(request), "request ID")

    assert Bonfire.Social.Follows.requested?(follower, followed)

    assert {:ok, follow} = Bonfire.Social.Follows.accept(request, current_user: followed)
    # assert not is_nil(request.accepted_at)
    assert Bonfire.Social.Follows.following?(follower, followed)

    {:ok, unfollow_activity} = ActivityPub.unfollow(ap_follower, ap_followed)

    Bonfire.Federate.ActivityPub.Receiver.receive_activity(unfollow_activity)
    refute Bonfire.Social.Follows.following?(follower, followed)
  end
end