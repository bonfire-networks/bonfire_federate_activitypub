defmodule Bonfire.Federate.ActivityPub.FollowIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Graph.Follows

  import Tesla.Mock

  @remote_instance "https://mocked.local"
  @actor_name "karen@mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    test_pid = self()

    mock(fn
      # records outgoing deliveries so tests can assert the payload actually reached an inbox
      %{method: :post, url: url, body: body} ->
        send(test_pid, {:delivered, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{
        method: :get,
        url: "https://mocked.local/.well-known/nodeinfo"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: url} ->
        url
        |> String.split("/pub/actors/")
        |> List.last()
        |> ActivityPub.Web.ActorView.actor_json()
        |> json()
    end)

    :ok
  end

  describe "" do
    test "follows get queued to federate" do
      me = fake_user!()
      followed = fake_user!()
      assert {:ok, follow} = Follows.follow(me, followed)

      ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(follow)
      assert %{__struct__: ActivityPub.Object} = ap_activity

      Oban.Testing.assert_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
      )
    end

    test "outgoing follow makes requests" do
      # debug(self(), "toppid")
      follower = fake_user!()
      {:ok, ap_followed} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      # info(followed)
      {:ok, follow} = Follows.follow(follower, followed)
      # info(follow)

      assert {:ok, _follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)
      refute Bonfire.Social.Graph.Follows.following?(follower, followed)
    end

    # COVERAGE GAP this closes: `push_now!` only performs the `publish` op, which ENQUEUES a `publish_one` job per inbox, so nothing above ever exercises signing-actor resolution or the actual POST. Draining the queue runs them, which is where a live probe against Lemmy died.
    test "outgoing follow is actually delivered to the remote inbox, as a spec-shaped payload" do
      follower = fake_user!()
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      {:ok, follow} = Follows.follow(follower, followed)

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

      queue = Oban.drain_queue(queue: :federator_outgoing)
      assert queue[:failure] == 0, "a delivery job failed: #{inspect(queue)}"

      assert_received {:delivered, url, body}
      assert url =~ "mocked.local"

      payload = Jason.decode!(body)
      assert payload["type"] == "Follow"
      assert payload["actor"] =~ id(follower)

      # `object` must stay a bare id: strict implementations (eg. Lemmy's `ObjectId`) can't deserialise an embedded actor, which `prepare_outgoing_object/1` used to produce
      assert is_binary(payload["object"]),
             "Follow object should reference the actor's id, got: #{inspect(payload["object"])}"
    end

    test "outgoing follow which then gets an Accept works" do
      follower = fake_user!()
      {:ok, ap_follower} = ActivityPub.Federator.Adapter.get_actor_by_id(follower.id)

      {:ok, ap_followed} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)

      {:ok, follow} = Follows.follow(follower, followed)

      assert {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)

      {:ok, accept} =
        ActivityPub.accept(%{
          actor: ap_followed,
          to: [ap_follower.data],
          object: follow_activity.data,
          local: false
        })

      # |> debug
      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(accept)

      assert Bonfire.Social.Graph.Follows.following?(follower, followed)
    end

    test "incoming follow request works" do
      followed = fake_user!(%{}, %{}, request_before_follow: true)
      # info(uid(followed), "followed ID") 
      {:ok, ap_followed} = ActivityPub.Federator.Adapter.get_actor_by_id(followed.id)

      {:ok, ap_follower} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      # info(uid(follower), "follower ID")

      {:ok, follow_activity} = ActivityPub.follow(%{actor: ap_follower, object: ap_followed})

      # |> debug
      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)
      refute Bonfire.Social.Graph.Follows.following?(follower, followed)
    end

    test "incoming follow + accept works" do
      followed = fake_user!(%{}, %{}, request_before_follow: true)
      # info(uid(followed), "followed ID")
      {:ok, ap_followed} = ActivityPub.Federator.Adapter.get_actor_by_id(followed.id)

      {:ok, ap_follower} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      # info(uid(follower), "follower ID")

      {:ok, follow_activity} = ActivityPub.follow(%{actor: ap_follower, object: ap_followed})

      # |> info("requested AP")
      assert {:ok, request} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

      # info(uid(request), "request ID")

      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)

      assert {:ok, follow} = Bonfire.Social.Graph.Follows.accept(request, current_user: followed)

      # assert not is_nil(request.accepted_at)
      assert Bonfire.Social.Graph.Follows.following?(follower, followed)
    end

    test "incoming follow + ignore works (does not federate rejections)" do
      followed = fake_user!(%{}, %{}, request_before_follow: true)
      info(uid(followed), "followed ID")
      {:ok, ap_followed} = ActivityPub.Federator.Adapter.get_actor_by_id(followed.id)

      {:ok, ap_follower} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      info(uid(follower), "follower ID")

      {:ok, follow_activity} = ActivityPub.follow(%{actor: ap_follower, object: ap_followed})

      assert {:ok, request} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
               |> info("request")

      assert {:ok, request} = Bonfire.Social.Graph.Follows.ignore(request, current_user: followed)

      assert not is_nil(request.ignored_at)

      refute Bonfire.Social.Graph.Follows.requested?(follower, followed)
    end

    test "incoming follow works" do
      # when you allow following without request
      followed = fake_user!(%{}, %{}, request_before_follow: false)
      info(uid(followed), "followed ID")
      {:ok, ap_followed} = ActivityPub.Federator.Adapter.get_actor_by_id(followed.id)

      {:ok, ap_follower} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      info(uid(follower), "follower ID")

      {:ok, follow_activity} = ActivityPub.follow(%{actor: ap_follower, object: ap_followed})

      assert {:ok, _} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity) |> debug

      assert Bonfire.Social.Graph.Follows.following?(follower, followed)
    end

    test "incoming follow / accept / unfollow works" do
      {:ok, ap_follower} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, follower} = Bonfire.Me.Users.by_ap_id(@remote_actor)

      followed = fake_user!(%{}, %{}, request_before_follow: true)
      {:ok, ap_followed} = ActivityPub.Federator.Adapter.get_actor_by_id(followed.id)

      {:ok, follow_activity} =
        ActivityPub.follow(%{actor: ap_follower, object: ap_followed, local: false})

      # |> info("requested AP")
      assert {:ok, request} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

      # info(uid(request), "request ID")

      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)

      assert {:ok, follow} = Bonfire.Social.Graph.Follows.accept(request, current_user: followed)

      # assert not is_nil(request.accepted_at)
      assert Bonfire.Social.Graph.Follows.following?(follower, followed)

      {:ok, unfollow_activity} =
        ActivityPub.unfollow(%{actor: ap_follower, object: ap_followed, local: false})
        |> debug("unfollow_activity")

      Bonfire.Federate.ActivityPub.Incoming.receive_activity(unfollow_activity)
      refute Bonfire.Social.Graph.Follows.following?(follower, followed)
    end
  end
end
