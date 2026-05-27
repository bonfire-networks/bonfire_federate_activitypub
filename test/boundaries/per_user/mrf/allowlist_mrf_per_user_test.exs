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
    test "local activity to non-allowlisted remote recipient is filtered when user is in allowlist mode" do
      local_user = fake_user!(@local_actor)

      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: local_user
      )

      local_activity =
        local_activity_json(local_user, [@remote_actor, ActivityPub.Config.public_uri()])

      assert {:ok, filtered} = BoundariesMRF.filter(local_activity, true)
      assert filtered.to == [ActivityPub.Config.public_uri()]
    end

    test "local activity to allowlisted remote recipient passes when user is in allowlist mode" do
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
