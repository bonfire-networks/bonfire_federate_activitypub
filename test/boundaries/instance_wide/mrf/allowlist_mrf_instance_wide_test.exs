defmodule Bonfire.Federate.ActivityPub.MRF.AllowlistInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub, as: Federation

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  @local_actor "alice"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  setup do
    Process.put(:federating, :allowlist_only)
    :ok
  end

  describe "incoming: reject when origin not allowlisted" do
    test "remote activity from non-allowlisted domain is rejected" do
      remote_activity = remote_activity_json()
      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_activity, false))
    end
  end

  describe "incoming: allow when origin is allowlisted" do
    test "remote activity from allowlisted domain passes" do
      Instances.add_to_allowlist("mocked.local")

      remote_activity = remote_activity_json()
      assert {:ok, _} = BoundariesMRF.filter(remote_activity, false)
    end
  end

  describe "allowlisted + blocked = rejected (blocks win)" do
    test "remote activity is rejected even when allowlisted if instance is also blocked" do
      Instances.add_to_allowlist("mocked.local")

      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :total, :instance_wide)

      remote_activity = remote_activity_json()
      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_activity, false))
    end
  end

  describe "outgoing: non-allowlisted recipients are filtered" do
    test "local activity to non-allowlisted remote actor has that recipient removed" do
      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert {:ok, filtered} = BoundariesMRF.filter(local_activity, true)
      # remote recipient filtered out; public URI stays
      assert filtered.to == [ActivityPub.Config.public_uri()]
    end

    test "local activity to only non-allowlisted recipient is rejected/ignored" do
      local_activity = local_activity_json_to(@remote_actor)
      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end
  end

  describe "outgoing: allowlisted recipients pass" do
    test "local activity to allowlisted remote actor is delivered" do
      Instances.add_to_allowlist("mocked.local")

      local_activity = local_activity_json_to(@remote_actor)
      assert {:ok, _} = BoundariesMRF.filter(local_activity, true)
    end
  end

  describe "open mode: no allowlist filtering" do
    test "remote activity passes without allowlist when instance is in open mode" do
      Process.put(:federating, true)

      remote_activity = remote_activity_json()
      # open mode — no allowlist filtering, only block checks apply
      refute reject_or_no_recipients?(BoundariesMRF.filter(remote_activity, false))
    end
  end
end
