defmodule Bonfire.Federate.ActivityPub.FollowIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Graph.Follows

  import Tesla.Mock

  @remote_instance "https://mocked.local"
  @actor_name "karen@mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  # an actor that approves its followers by hand
  @locked_actor @remote_instance <> "/users/locked"

  setup do
    test_pid = self()

    mock(fn
      # records outgoing deliveries so tests can assert the payload actually reached an inbox
      %{method: :post, url: url, body: body} ->
        send(test_pid, {:delivered, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @locked_actor} ->
        json(Simulate.actor_json(@locked_actor, "locked", %{"manuallyApprovesFollowers" => true}))

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

  describe "following by URI" do
    # a remote actor we have never seen, named only by its URI: the context fetches it
    test "Follows.follow/3 takes a URI, fetching the actor through federation" do
      me = fake_user!()

      assert {:ok, _} = Follows.follow(me, @remote_actor)

      {:ok, remote} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(@remote_actor)

      assert Follows.following?(me, remote) or Follows.requested?(me, remote)

      # and unfollowing by URI too
      assert {:ok, _} = Follows.unfollow(me, @remote_actor)
      refute Follows.following?(me, remote) or Follows.requested?(me, remote)
    end

    test "the GraphQL `follow` resolver passes a URI to Follows, through Nomad in process" do
      me = fake_user!()

      assert {:ok, %{"id" => _}} =
               Follows.nomad(:follow, me, @remote_actor,
                 current_user: me,
                 nomad_transport: :graphql
               )

      {:ok, remote} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(@remote_actor)

      assert Follows.following?(me, remote) or Follows.requested?(me, remote)
    end
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

    # A request can be our own bookkeeping, such as a moderator's action on a group hosted elsewhere waiting for the group to apply it, where the real activity goes out separately and the request itself must not: `skip_federation: true`
    test "a request made with skip_federation stays on this instance" do
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)

      sender = fake_user!()

      assert {:ok, sent} =
               Bonfire.Social.Requests.request(sender, Bonfire.Data.Social.Follow, followed)

      assert {:ok, _} = ActivityPub.Object.get_cached(pointer: id(sent)),
             "control: a request to someone on another instance federates"

      keeper = fake_user!()

      assert {:ok, kept} =
               Bonfire.Social.Requests.request(keeper, Bonfire.Data.Social.Follow, followed,
                 skip_federation: true
               )

      assert Bonfire.Social.Requests.requested?(keeper, Bonfire.Data.Social.Follow, followed)

      refute match?({:ok, _}, ActivityPub.Object.get_cached(pointer: id(kept))),
             "nothing was sent for it"
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

  # Lemmy 0.19 never sends the Accept of the first Follow it gets from an instance it hadn't seen, so a Follow still pending a few minutes after its delivery is sent once more, with a new id
  describe "re-sending a pending Follow" do
    test "a delivered Follow queues one check for a re-send" do
      %{follow_activity: follow_activity} = follow_and_deliver()

      assert [job] = resend_checks()
      assert job.args["follow_id"] == follow_activity.data["id"]

      seconds_ahead = DateTime.diff(job.scheduled_at, DateTime.utc_now())

      assert seconds_ahead in 230..240,
             "the check should run about 4 minutes after the delivery, it runs in #{seconds_ahead}s"
    end

    test "a Follow still pending when the check runs is sent once more, with a new id, and that id is stored" do
      %{follow_activity: follow_activity} = follow_and_deliver()
      first_id = follow_activity.data["id"]

      assert [check] = resend_checks()
      assert {:ok, _} = run_check(check)

      drain_deliveries()

      assert [%{"id" => resent_id}] =
               delivered_follows() |> Enum.uniq_by(& &1["id"]),
             "one more Follow was delivered"

      assert resent_id != first_id, "the re-sent Follow has a new id"
      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: resent_id), "and it is stored"

      assert [] == resend_checks(%{"follow_id" => resent_id}),
             "the re-sent Follow gets no check of its own"

      assert [%{args: %{"follow_id" => ^first_id}}] = resend_checks()
    end

    test "an Accept of the re-sent Follow makes us a follower" do
      %{
        follower: follower,
        followed: followed,
        ap_follower: ap_follower,
        ap_followed: ap_followed,
        follow_activity: follow_activity
      } = follow_and_deliver()

      resent = resend_now()

      {:ok, accept} =
        ActivityPub.accept(%{
          actor: ap_followed,
          to: [ap_follower.data],
          object: resent.data,
          local: false
        })

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(accept)

      assert Follows.following?(follower, followed)
      assert stored_state(follow_activity) == "accept"
      assert stored_state(resent) == "accept"
    end

    test "no re-send once the Follow was Accepted" do
      %{
        follower: follower,
        followed: followed,
        ap_follower: ap_follower,
        ap_followed: ap_followed,
        follow_activity: follow_activity
      } = follow_and_deliver()

      {:ok, accept} =
        ActivityPub.accept(%{
          actor: ap_followed,
          to: [ap_follower.data],
          object: follow_activity.data,
          local: false
        })

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(accept)
      assert Follows.following?(follower, followed), "control: the Accept made us a follower"

      assert_no_resend(follow_activity)
    end

    test "no re-send once it was Rejected" do
      %{
        follower: follower,
        followed: followed,
        ap_follower: ap_follower,
        ap_followed: ap_followed,
        follow_activity: follow_activity
      } = follow_and_deliver()

      {:ok, reject} =
        ActivityPub.reject(%{
          actor: ap_followed,
          to: [ap_follower.data["id"]],
          object: follow_activity.data["id"],
          local: false
        })

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(reject)
      refute Follows.requested?(follower, followed), "control: the Reject ended the request"

      assert_no_resend(follow_activity)
    end

    test "no re-send after an unfollow" do
      %{follower: follower, followed: followed, follow_activity: follow_activity} =
        follow_and_deliver()

      assert {:ok, _} = Follows.unfollow(follower, followed)
      refute Follows.requested?(follower, followed), "control: the request was withdrawn"
      drain_deliveries()

      assert_no_resend(follow_activity)
    end

    test "no re-send for a Follow that a newer one replaced" do
      %{follower: follower, followed: followed, follow_activity: follow_activity} =
        follow_and_deliver()

      assert {:ok, _} = Follows.unfollow(follower, followed)
      drain_deliveries()

      assert {:ok, _} = Follows.follow(follower, followed)
      assert Follows.requested?(follower, followed), "control: we asked to follow again"
      drain_deliveries()

      assert [%{"id" => newer_id} | _] = delivered_follows(), "control: a newer Follow went out"
      assert newer_id != follow_activity.data["id"]

      assert_no_resend(follow_activity)
    end

    test "no check for an actor that approves followers by hand" do
      %{follower: follower, followed: followed} = follow_and_deliver(@locked_actor)
      assert Follows.requested?(follower, followed), "control: the follow is pending"

      assert [] == resend_checks()
    end

    test "the check snoozes while the host is failing" do
      %{follow_activity: follow_activity} = follow_and_deliver()
      inbox = "https://mocked.local/users/karen/inbox"

      ActivityPub.Instances.set_unreachable(inbox, NaiveDateTime.add(now(), -3600))

      delivered_follows()
      assert [check] = resend_checks(%{"follow_id" => follow_activity.data["id"]})
      assert {:snooze, seconds} = run_check(check)
      assert seconds > 0

      drain_deliveries()
      assert [] == delivered_follows(), "no Follow was re-sent"
    end

    test "the check is cancelled once the host is written off" do
      %{follow_activity: follow_activity} = follow_and_deliver()
      inbox = "https://mocked.local/users/karen/inbox"

      # failing for longer than a delivery is kept
      max_age_days = ActivityPub.Config.get([:instance, :federation_delivery_max_age_days], 6)

      ActivityPub.Instances.set_unreachable(
        inbox,
        NaiveDateTime.add(now(), -(max_age_days + 1) * 24 * 3600)
      )

      delivered_follows()
      assert [check] = resend_checks(%{"follow_id" => follow_activity.data["id"]})
      assert {:cancel, _} = run_check(check)

      Oban.Testing.refute_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish"}
      )

      drain_deliveries()
      assert [] == delivered_follows(), "no Follow was re-sent"
    end

    test "with `:resend_pending_follow_after` set to `false`, no check is queued" do
      previous = Application.fetch_env(:activity_pub, :resend_pending_follow_after)
      Application.put_env(:activity_pub, :resend_pending_follow_after, false)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:activity_pub, :resend_pending_follow_after, value)
          :error -> Application.delete_env(:activity_pub, :resend_pending_follow_after)
        end
      end)

      follow_and_deliver()

      assert [] == resend_checks()
    end
  end

  defp now, do: NaiveDateTime.utc_now(Calendar.ISO) |> NaiveDateTime.truncate(:second)

  # runs the check of this Follow: it cancels, and delivers nothing
  defp assert_no_resend(follow_activity) do
    # whatever went out before the check
    delivered_follows()

    assert [check] = resend_checks(%{"follow_id" => follow_activity.data["id"]})
    assert {:cancel, _} = run_check(check)

    drain_deliveries()
    assert [] == delivered_follows(), "no Follow was re-sent"
  end

  # follows a remote actor, then runs the delivery jobs, so the Follow reaches the mocked inbox
  defp follow_and_deliver(actor_id \\ @remote_actor) do
    follower = fake_user!()
    {:ok, ap_follower} = ActivityPub.Federator.Adapter.get_actor_by_id(follower.id)
    {:ok, ap_followed} = ActivityPub.Actor.get_cached_or_fetch(ap_id: actor_id)
    {:ok, followed} = Bonfire.Me.Users.by_ap_id(actor_id)

    {:ok, follow} = Follows.follow(follower, followed)
    assert {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    drain_deliveries()

    assert [%{"id" => delivered_id} | _] = delivered_follows(),
           "control: the Follow was delivered"

    assert delivered_id == follow_activity.data["id"]

    %{
      follower: follower,
      followed: followed,
      ap_follower: ap_follower,
      ap_followed: ap_followed,
      follow_activity: follow_activity
    }
  end

  # runs what is queued for delivery now, and the deliveries those jobs queue, but not what is scheduled later (such as the check itself)
  defp drain_deliveries do
    queue = Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    assert queue[:failure] == 0, "a delivery job failed: #{inspect(queue)}"
    queue
  end

  # the Follows that reached an inbox since the last call, read from the mailbox
  defp delivered_follows(acc \\ []) do
    receive do
      {:delivered, _url, body} ->
        case Jason.decode!(body) do
          %{"type" => "Follow"} = follow -> delivered_follows(acc ++ [follow])
          _ -> delivered_follows(acc)
        end
    after
      0 -> acc
    end
  end

  # runs the queued check as Oban would when it is due
  defp run_check(check), do: ActivityPub.Federator.Workers.PublisherWorker.perform(check)

  # runs the one queued check, and returns the Follow it re-sent
  defp resend_now do
    assert [check] = resend_checks()
    assert {:ok, _} = run_check(check)
    drain_deliveries()

    assert [%{"id" => resent_id} | _] = delivered_follows(), "control: a Follow was re-sent"
    {:ok, resent} = ActivityPub.Object.get_cached(ap_id: resent_id)
    resent
  end

  # read from the database, as the cache may hold an older copy
  defp stored_state(%{id: id}), do: repo().get!(ActivityPub.Object, id).data["state"]

  defp resend_checks(args \\ %{}) do
    Oban.Testing.all_enqueued(repo(),
      worker: ActivityPub.Federator.Workers.PublisherWorker,
      args: Map.merge(%{"op" => "resend_pending_follow"}, args)
    )
  end
end
