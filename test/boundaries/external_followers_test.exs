defmodule Bonfire.Federate.ActivityPub.ExternalFollowersTest do
  @moduledoc """
  Unit tests for Adapter.external_followers_for_activity/3 — verifies that
  remote followers excluded by blocks or allowlist mode are not included in
  the BCC fanout list for local activities.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: true
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Posts

  @remote_actor "https://mocked.local/users/karen"
  @local_actor "alice"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: "https://mocked.local/.well-known/webfinger" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo" <> _} ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  setup do
    Process.put(:federating, true)

    local_user = fake_user!(@local_actor)
    {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)
    {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    # remote actor follows local user
    {:ok, follow_activity} =
      ActivityPub.follow(%{actor: remote_actor, object: local_actor, local: false})

    {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

    # publish a public post so an AP object exists in the cache
    {:ok, post} =
      Posts.publish(
        current_user: local_user,
        post_attrs: %{post_content: %{html_body: "<p>hello world</p>"}},
        boundary: "public"
      )

    {:ok, ap_object} = ActivityPub.Object.get_cached(pointer: post.id)
    activity_data = %{"object" => %{"id" => ap_object.data["id"]}}

    {:ok,
     local_user: local_user,
     local_actor: local_actor,
     remote_actor: remote_actor,
     activity_data: activity_data}
  end

  describe "external_followers_for_activity/3" do
    test "includes remote followers in open mode", %{
      local_actor: local_actor,
      remote_actor: remote_actor,
      activity_data: activity_data
    } do
      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))
    end

    test "excludes specifically blocked remote follower", %{
      local_actor: local_actor,
      remote_actor: remote_actor,
      activity_data: activity_data
    } do
      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(remote_user, :ghost, :instance_wide)

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      refute Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))
    end

    test "excludes followers from instance-wide blocked instance", %{
      local_actor: local_actor,
      remote_actor: remote_actor,
      activity_data: activity_data
    } do
      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:ghost, :instance_wide)

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      refute Enum.any?(followers, &String.contains?(&1.ap_id, "mocked.local"))
    end

    test "excludes followers from non-allowlisted instance in allowlist-only mode", %{
      local_actor: local_actor,
      remote_actor: remote_actor,
      activity_data: activity_data
    } do
      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))

      Process.put(:federating, :allowlist_only)

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert followers == []
    end

    test "includes specifically allowlisted remote follower in allowlist-only mode (domain not allowlisted)",
         %{
           local_actor: local_actor,
           remote_actor: remote_actor,
           activity_data: activity_data
         } do
      Process.put(:federating, :allowlist_only)

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      refute Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))

      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered)

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))
    end

    test "includes followers from allowlisted instance in allowlist-only mode", %{
      local_actor: local_actor,
      remote_actor: remote_actor,
      activity_data: activity_data
    } do
      Process.put(:federating, :allowlist_only)
      Instances.add_to_allowlist("mocked.local")

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))
    end

    test "excludes followers from non-allowlisted instance when author has allowlist-only mode",
         %{
           local_actor: local_actor,
           remote_actor: remote_actor,
           local_user: local_user,
           activity_data: activity_data
         } do
      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))

      local_user =
        current_user(
          Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
            current_user: local_user
          )
        )

      {:ok, local_actor} =
        ActivityPub.Federator.Adapter.get_actor_by_id(local_user)
        |> info("updated local_actor with user_federating: :allowlist_only")

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert followers == []
    end

    test "includes followers from allowlisted instance when author has allowlist-only mode", %{
      local_user: local_user,
      local_actor: local_actor,
      remote_actor: remote_actor,
      activity_data: activity_data
    } do
      local_user =
        current_user(
          Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
            current_user: local_user
          )
        )

      Instances.add_to_allowlist("mocked.local", current_user: local_user)

      assert {:ok, followers} =
               Adapter.external_followers_for_activity(local_actor, activity_data)

      assert Enum.any?(followers, &(&1.ap_id == remote_actor.ap_id))
    end
  end
end
