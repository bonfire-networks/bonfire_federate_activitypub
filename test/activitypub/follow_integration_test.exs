defmodule Bonfire.Federate.ActivityPub.FollowIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Follows

  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    :ok
  end

  test "follow publishing works" do
    follower = fake_user!()
    followed = fake_user!()
    {:ok, follow} = Follows.follow(follower, followed)

    assert {:ok, _follow_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", follow)
  end

  test "follow receiving works" do
    followed = fake_user!()
    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)
    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)
  end

  test "unfollow receiving works" do
    followed = fake_user!()
    {:ok, ap_follower} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    {:ok, ap_followed} = ActivityPub.Adapter.get_actor_by_id(followed.id)
    {:ok, follow_activity} = ActivityPub.follow(ap_follower, ap_followed)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)

    {:ok, unfollow_activity} = ActivityPub.unfollow(ap_follower, ap_followed)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(unfollow_activity)
  end
end
