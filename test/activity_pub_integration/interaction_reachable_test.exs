defmodule Bonfire.Federate.ActivityPub.InteractionReachableTest do
  @moduledoc """
  Tests for `Bonfire.Federate.ActivityPub.interaction_reachable?/3` — whether the current user can
  have a FEDERATED interaction (follow/reply/like/boost/DM) delivered to a target, accounting for
  the effective federation mode (open / allowlist-only / manual / disabled). See bonfire-app#647/#2058.

  Local targets are always reachable (no federation needed). Remote targets are reachable only
  when federation is open, or — under allowlist-only — when the target is allowlisted.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :ui

  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub.Simulate

  setup do
    # default to open federation; reset after each test (cross-process, see allowlist_settings_test)
    Bonfire.Federate.ActivityPub.set_federating(:instance, true)

    on_exit(fn ->
      parent = self()

      Task.start(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Bonfire.Common.Repo, parent, self())
        Bonfire.Federate.ActivityPub.set_federating(:instance, true)
      end)
    end)

    me = fake_user!()
    {:ok, me: me}
  end

  defp remote_actor(ap_id, extra \\ %{}) do
    base = Simulate.actor_json("https://mocked.local/users/karen")
    username = ap_id |> URI.parse() |> Map.get(:path) |> String.split("/") |> List.last()

    json =
      base
      |> Map.merge(%{
        "id" => ap_id,
        "preferredUsername" => username,
        "inbox" => ap_id <> "/inbox",
        "outbox" => ap_id <> "/outbox",
        "followers" => ap_id <> "/followers",
        "following" => ap_id <> "/following",
        "publicKey" => %{
          "id" => ap_id <> "#main-key",
          "owner" => ap_id,
          "publicKeyPem" => base["publicKey"]["publicKeyPem"]
        }
      })
      |> Map.merge(extra)

    mock(fn %{method: :get, url: ^ap_id} -> json(json) end)
    {:ok, char} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(json)
    char
  end

  describe "interaction_allowed?/3" do
    test "a LOCAL target is always federatable, even with federation disabled", %{me: me} do
      Bonfire.Federate.ActivityPub.set_federating(:instance, false)
      other = fake_user!()

      assert Bonfire.Federate.ActivityPub.interaction_allowed?(me, other)
    end

    test "a REMOTE target is federatable when federation is open", %{me: me} do
      a = remote_actor("https://mocked.local/users/r_open")

      assert Bonfire.Federate.ActivityPub.interaction_allowed?(me, a)
    end

    test "a REMOTE target is NOT federatable when federation is disabled", %{me: me} do
      # create the remote actor while open, THEN disable (fetching a remote actor is itself
      # blocked under restricted modes — set the mode after the actor exists locally)
      a = remote_actor("https://mocked.local/users/r_off")
      Bonfire.Federate.ActivityPub.set_federating(:instance, false)

      refute Bonfire.Federate.ActivityPub.interaction_allowed?(me, a)
    end

    test "a REMOTE target is NOT federatable in manual mode", %{me: me} do
      a = remote_actor("https://mocked.local/users/r_manual")

      Bonfire.Common.Settings.set([activity_pub: [instance: [federating: :manual]]],
        scope: :instance,
        skip_boundary_check: true
      )

      refute Bonfire.Federate.ActivityPub.interaction_allowed?(me, a)
    end

    test "a REMOTE target is NOT federatable in allowlist-only mode unless allowlisted", %{me: me} do
      a = remote_actor("https://mocked.local/users/r_archi")
      Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, true)

      refute Bonfire.Federate.ActivityPub.interaction_allowed?(me, a)
    end
  end
end
