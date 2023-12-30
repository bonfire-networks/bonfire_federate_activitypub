defmodule Bonfire.Federate.ActivityPub.BoostIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Posts
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Social.Boosts

  import Bonfire.Federate.ActivityPub
  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))
    end)

    :ok
  end

  describe "" do
    test "boosts get queued to federate" do
      me = fake_user!()
      post_creator = fake_user!()

      attrs = %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, boosted} =
               Posts.publish(
                 current_user: post_creator,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, boost} = Boosts.boost(me, boosted)

      ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(boost)
      assert %{__struct__: ActivityPub.Object} = ap_activity

      Oban.Testing.assert_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
      )
    end

    test "boost publishing works" do
      user = fake_user!()
      booster = fake_user!()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      {:ok, boost} = Boosts.boost(booster, post)

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(boost)
    end

    test "boost receiving works" do
      user = fake_user!()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      {:ok, actor} =
        ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

      {:ok, ap_boost} = ActivityPub.announce(%{actor: actor, object: ap_activity.object})

      assert {:ok, %Boost{} = boost_pointer} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_boost)

      assert Bonfire.Social.FeedActivities.feed_contains?(
               :notifications,
               [activity: boost_pointer.activity],
               current_user: user
             )
    end

    test "boost receiving works, but doesn't notify me if I disabled federation" do
      user = fake_user!()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      {:ok, actor} =
        ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

      # now disable federation
      user =
        Bonfire.Federate.ActivityPub.disable(user)
        ~> current_user()

      {:ok, ap_boost} = ActivityPub.announce(%{actor: actor, object: ap_activity.object})

      assert {:ok, boost_pointer} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_boost)

      refute Bonfire.Social.FeedActivities.feed_contains?(
               :notifications,
               [activity: boost_pointer.activity],
               current_user: user
             )
    end

    test "unboost receiving works" do
      user = fake_user!()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      {:ok, actor} =
        ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

      {:ok, ap_boost} = ActivityPub.announce(%{actor: actor, object: ap_activity.object})

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_boost)

      {:ok, ap_unboost} = ActivityPub.unannounce(%{actor: actor, object: ap_activity.object})

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_unboost)
    end

    # test "boost receiving works, using a raw object" do
    #   ap_boost = %{
    #     data: %{
    #       "object" => %{
    #         "actor" => "https://mocked.local/users/karen",
    #         "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
    #         "context" => nil,
    #         "id" => "https://mocked.local/users/karen/statuses/108585154815961343/activity",
    #         "object" => "https://misskey.bubbletea.dev/notes/9296rwt5fk",
    #         "published" => "2022-07-03T19:52:57.212971Z",
    #         "summary" => nil,
    #         "to" => [
    #           "https://mocked.local/users/karen/followers",
    #           "https://misskey.bubbletea.dev/users/8r0vwokp46"
    #         ],
    #         "type" => "Announce"
    #       }
    #     }
    #   }

    #   assert {:ok, %Boost{}} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_boost) |> repo().maybe_preload(:caretaker, activity: [:subject]) |> debug
    # end
  end
end
