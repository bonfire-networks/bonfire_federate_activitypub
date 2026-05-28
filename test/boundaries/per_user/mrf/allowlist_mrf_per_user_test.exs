defmodule Bonfire.Federate.ActivityPub.MRF.AllowlistPerUserTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub, as: Federation

  @remote_actor "https://mocked.local/users/karen"
  @local_actor "alice"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  describe "per-user allowlist-only mode: outgoing" do
    test "local direct activity to non-allowlisted remote recipient is filtered when user is in allowlist mode" do
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      local_activity = local_activity_json(local_user, @remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "local public activity to non-allowlisted remote recipient is filtered when user is in allowlist mode" do
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      local_activity =
        local_activity_json(local_user, [@remote_actor, ActivityPub.Config.public_uri()])

      assert {:ok, filtered} = BoundariesMRF.filter(local_activity, true)
      refute @remote_actor in (filtered[:to] || [])
      assert ActivityPub.Config.public_uri() in (filtered[:to] || [])
    end

    test "local public activity to allowlisted remote recipient passes when user is in allowlist mode" do
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      Instances.add_to_allowlist("mocked.local", current_user: local_user)

      local_activity =
        local_activity_json(local_user, [@remote_actor, ActivityPub.Config.public_uri()])

      assert {:ok, filtered} = BoundariesMRF.filter(local_activity, true)
      assert @remote_actor in (filtered[:to] || [])
      assert ActivityPub.Config.public_uri() in (filtered[:to] || [])
    end

    test "local direct activity to allowlisted remote recipient passes when user is in allowlist mode" do
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      Instances.add_to_allowlist("mocked.local", current_user: local_user)

      local_activity = local_activity_json(local_user, @remote_actor)
      assert {:ok, _} = BoundariesMRF.filter(local_activity, true)
    end
  end

  describe "per-user allowlist-only mode: incoming" do
    test "incoming activity is filtered for user in allowlist mode but not for open user" do
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      open_user = fake_user!("bob")

      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)
      {:ok, open_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(open_user.id)

      # activity addressed to both users — allowlist-only user gets filtered, open user stays
      remote_activity = remote_activity_json(@remote_actor, [local_actor.ap_id, open_actor.ap_id])

      assert {:ok, filtered} = BoundariesMRF.filter(remote_activity, false)
      refute local_actor.ap_id in (filtered[:to] || filtered["to"] || [])
      assert open_actor.ap_id in (filtered[:to] || filtered["to"] || [])
    end
  end

  describe "per-user allowlist-only mode: actor-level allowlist" do
    test "outgoing: specific actor in user allowlist passes (domain not allowlisted)" do
      local_user = fake_user!(@local_actor)
      # fetch actor in open mode so Peered record exists, then set user to allowlist-only
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, current_user: local_user)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      local_activity = local_activity_json(local_user, @remote_actor)
      assert {:ok, _} = BoundariesMRF.filter(local_activity, true)
    end

    test "incoming: specific actor in user allowlist — user stays in to (domain not allowlisted)" do
      local_user = fake_user!(@local_actor)
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, current_user: local_user)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)
      remote_activity = remote_activity_json(@remote_actor, [local_actor.ap_id])

      assert {:ok, filtered} = BoundariesMRF.filter(remote_activity, false)
      assert local_actor.ap_id in (filtered[:to] || filtered["to"] || [])
    end
  end

  describe "instance allowlist-only + user allowlist aggregation" do
    test "outgoing: user allowlist extends instance — actor allowlisted only at user level is delivered" do
      local_user = fake_user!(@local_actor)
      # fetch in open mode, allowlist actor for user, then activate instance allowlist-only
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, current_user: local_user)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      Process.put(:federating, :allowlist_only)

      local_activity = local_activity_json(local_user, @remote_actor)
      assert {:ok, _} = BoundariesMRF.filter(local_activity, true)
    end

    test "outgoing: not in instance or user allowlist is rejected" do
      Process.put(:federating, :allowlist_only)
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      local_activity = local_activity_json(local_user, @remote_actor)
      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "incoming addressed: user allowlist extends instance — actor allowlisted only at user level, user stays in to" do
      local_user = fake_user!(@local_actor)
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, current_user: local_user)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      Process.put(:federating, :allowlist_only)

      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)
      remote_activity = remote_activity_json(@remote_actor, [local_actor.ap_id])

      assert {:ok, filtered} = BoundariesMRF.filter(remote_activity, false)
      assert local_actor.ap_id in (filtered[:to] || filtered["to"] || [])
    end

    test "incoming addressed: actor not in instance or user allowlist — user removed from to (activity rejected)" do
      Process.put(:federating, :allowlist_only)
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)
      remote_activity = remote_activity_json(@remote_actor, [local_actor.ap_id])

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_activity, false))
    end

    test "incoming public broadcast: user allowlist does not apply — rejected at instance level" do
      local_user = fake_user!(@local_actor)
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, current_user: local_user)

      Process.put(:federating, :allowlist_only)

      # public broadcast: to is just the public URI, not specifically addressed to local_user
      public_activity = remote_activity_json(@remote_actor, [ActivityPub.Config.public_uri()])
      assert reject_or_no_recipients?(BoundariesMRF.filter(public_activity, false))
    end

    test "outgoing public: user allowlist for actor extends instance allowlist — remote actor passes" do
      local_user = fake_user!(@local_actor)
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, current_user: local_user)

      Process.put(:federating, :allowlist_only)

      local_activity =
        local_activity_json(local_user, [@remote_actor, ActivityPub.Config.public_uri()])

      assert {:ok, filtered} = BoundariesMRF.filter(local_activity, true)
      assert @remote_actor in (filtered[:to] || [])
      assert ActivityPub.Config.public_uri() in (filtered[:to] || [])
    end
  end

  describe "instance allowlist-only overrides open user" do
    test "instance in allowlist mode blocks non-allowlisted even for open users" do
      Process.put(:federating, :allowlist_only)

      local_user = fake_user!(@local_actor)
      # user is explicitly open, but instance overrides
      Bonfire.Common.Settings.put([:activity_pub, :user_federating], true,
        current_user: local_user
      )

      local_activity = local_activity_json(local_user, @remote_actor)
      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end
  end
end
