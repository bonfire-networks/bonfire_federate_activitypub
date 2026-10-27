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
    end)

    :ok
  end

  # an `Undo` sent by this actor of this activity, whether it names the activity by id or embeds it
  defp undo_of?(actor_ap_id, activity_ap_id) do
    ActivityPub.Object
    |> repo().all()
    |> Enum.any?(
      &(&1.data["type"] == "Undo" and &1.data["actor"] == actor_ap_id and
          ActivityPub.Object.get_ap_id(&1.data["object"]) == activity_ap_id)
    )
  end

  describe "" do
    test "boosts get queued to federate" do
      me = fake_user!()
      post_creator = fake_user!()

      attrs = %{
        post_content: %{
          summary: "summary",
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

    # taking a boost back has to reach the servers the boost reached, or they keep showing it: `ap_publish_activity(_, :delete, boost)` sends the `Undo{Announce}`, which unboosting used to never call
    test "unboosting federates an Undo of the boost" do
      user = fake_user!()
      booster = fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "content"}},
          boundary: "public"
        )

      {:ok, _boost} = Boosts.boost(booster, post)
      {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)
      {:ok, booster_actor} = ActivityPub.Actor.get_cached(pointer: booster)

      assert %{data: announce} =
               ActivityPub.Object.get_existing_announce(booster_actor.ap_id, ap_post),
             "control: the boost was federated, so there is an Announce to undo"

      assert {:ok, _} = Boosts.unboost(booster, post)

      assert undo_of?(booster_actor.ap_id, announce["id"]),
             "unboosting sent no Undo, so remote servers keep showing the boost"
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

      assert Bonfire.Social.FeedLoader.feed_contains?(
               :notifications,
               [activity: boost_pointer.activity],
               current_user: user
             )
    end

    # ActivityPub asks the adapter whether this actor already has a live boost of this object, to discard a duplicate Announce (`Transformer.duplicate_announce?/2`). The module answering is `Bonfire.Social.Boosts`, and extensions and modules are toggled at runtime: while it is disabled it answers nothing, so the duplicate is not discarded.
    #
    # Only the module is disabled here, not its extension: the answer goes through `Bonfire.Social.Edges`, which is in the same extension, and would be disabled with it, so that would not show the check on the module
    test "a received boost is a live interaction, unless the module answering for it is disabled" do
      user = fake_user!()
      attrs = %{post_content: %{html_body: "content"}}
      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")
      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      {:ok, actor} =
        ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

      {:ok, ap_boost} = ActivityPub.announce(%{actor: actor, object: ap_activity.object})

      assert {:ok, %Boost{}} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_boost)

      exists? = fn ->
        ActivityPub.Federator.Adapter.activity_exists?(
          "Announce",
          actor.ap_id,
          ap_activity.object.data["id"]
        )
      end

      key = [:bonfire_social, Bonfire.Social.Boosts, :modularity]

      # the positive first: the boost just received is found
      assert exists?.()

      Bonfire.Common.Extend.clear_modularity_cache(Bonfire.Social.Boosts)
      Process.put(key, :disabled)

      try do
        refute exists?.()
      after
        Process.delete(key)
        Bonfire.Common.Extend.clear_modularity_cache(Bonfire.Social.Boosts)
      end

      assert exists?.()
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

      refute Bonfire.Social.FeedLoader.feed_contains?(
               :notifications,
               [activity: boost_pointer.activity],
               current_user: user
             )
    end

    # a repeat boost from another instance is decided by the same rule as a local one (`can_reboost_after`): not discarded on receipt as a duplicate while the first boost stands
    defp remote_reboost_setup do
      user = fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "content"}},
          boundary: "public"
        )

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      {:ok, actor} =
        ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

      {:ok, booster} = Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(actor)

      announce = fn n ->
        ActivityPub.Federator.Transformer.handle_incoming(
          %{
            "id" => "#{actor.ap_id}/announces/#{System.unique_integer([:positive])}-#{n}",
            "type" => "Announce",
            "actor" => actor.ap_id,
            "to" => ["https://www.w3.org/ns/activitystreams#Public"],
            "object" => ap_activity.object.data["id"]
          },
          from_inbox: true,
          authenticated: :http_signature,
          signed_by: actor.ap_id
        )
      end

      %{post: post, booster: booster, announce: announce}
    end

    test "a remote reboost is received when this instance allows reboosts" do
      context = remote_reboost_setup()
      Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], true)

      assert {:ok, %{data: %{"id" => first_id}}} = context.announce.(1)
      assert 1 == Boosts.count(context.booster, context.post), "control: the first boost landed"

      # received longer ago than `duplicate_announce_window`, within which a second one is taken as a remote's duplicate copy
      repo().update_all(
        from(o in ActivityPub.Object, where: fragment("(?)->>'id' = ?", o.data, ^first_id)),
        set: [
          updated_at:
            NaiveDateTime.add(NaiveDateTime.utc_now(), -to_timeout(hour: 1), :millisecond)
        ]
      )

      context.announce.(2)

      assert 2 == Boosts.count(context.booster, context.post),
             "the reboost was discarded on receipt as a duplicate"
    end

    test "a second remote boost right after the first is a duplicate copy, even where reboosts are always allowed" do
      context = remote_reboost_setup()
      Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], true)

      assert {:ok, _} = context.announce.(1)
      assert 1 == Boosts.count(context.booster, context.post), "control: the first boost landed"

      context.announce.(2)

      assert 1 == Boosts.count(context.booster, context.post),
             "a copy within the window was taken as a reboost"
    end

    test "a remote reboost is not a second boost when this instance does not allow reboosts" do
      context = remote_reboost_setup()
      Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], false)

      assert {:ok, _} = context.announce.(1)
      assert 1 == Boosts.count(context.booster, context.post), "control: the first boost landed"

      context.announce.(2)

      assert 1 == Boosts.count(context.booster, context.post)
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
