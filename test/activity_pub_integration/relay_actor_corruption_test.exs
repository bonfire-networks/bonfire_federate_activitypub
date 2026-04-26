defmodule Bonfire.Federate.ActivityPub.RelayActorCorruptionTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Federate.ActivityPub.RepairCorruptedActorPointers

  import Tesla.Mock
  use Repatch.ExUnit

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  @relay_instance "https://relay.example.com"
  @relay_actor @relay_instance <> "/users/relay"
  @relay_add_id @relay_instance <> "/user/relay/add/abc123"

  @peertube_instance "https://peertube.local"
  @peertube_group @peertube_instance <> "/u/testchannel"
  @peertube_person @peertube_instance <> "/accounts/testcreator"
  @peertube_video_id @peertube_instance <> "/videos/watch/abc456"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @relay_actor} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: @relay_add_id} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: @peertube_group} ->
        json(minimal_actor_json(@peertube_group, "testchannel", "Group"))

      %{method: :get, url: @peertube_person} ->
        json(minimal_actor_json(@peertube_person, "testcreator", "Person"))

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://relay.example.com/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://peertube.local/.well-known/nodeinfo"} ->
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

  defp minimal_actor_json(ap_id, username, type \\ "Person") do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => ap_id,
      "type" => type,
      "preferredUsername" => username,
      "inbox" => ap_id <> "/inbox",
      "outbox" => ap_id <> "/outbox",
      "followers" => ap_id <> "/followers",
      "following" => ap_id <> "/following",
      "publicKey" => %{
        "id" => ap_id <> "#main-key",
        "owner" => ap_id,
        "publicKeyPem" =>
          "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5FUojZbzUpD6L1Kof1gr\nh7GMSKd/N36FiekhhyDBAhtXgwEFgUWkiGLyDrNPP6RFFD/37FuZlq9JWSAonEHL\nbE4freE/FcuBP84AWQl/ZEm8BPCYVlHwALFEo13Gxg/VMetN37By0H7O7Lmb5JV4\nVgujqMaoNss03fwZARGd0LMLokN5KJExt7e1bsAqZOvI/xOBF1XlSRiHkco4OUGZ\nYjhoNbCKQtL995hGo14JlNd3QZI5RcBU47SqEuUYvgJXlyrVEKpqozBsFpGkh4/+\n9ck31bG50V3mLTL2SUthUdX9r8DgJVsxFYSb/rRMyPcCZAH8RD3FJH5deRtH1KJy\n7wIDAQAB\n-----END PUBLIC KEY-----\n\n"
      }
    }
  end

  describe "relay Add activity does not corrupt local user's AP actor" do
    test "Actor.get_cached by pointer ignores non-actor AP objects sharing the same pointer_id" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      # Inject a non-actor (Add activity) AP object with pointer_id = local user's ULID,
      # simulating DB corruption caused by the incoming.ex pointer_id fallback bug.
      add_activity_data = %{
        "id" => @relay_add_id,
        "type" => "Add",
        "actor" => @relay_actor,
        "object" => local_actor.ap_id
      }

      {:ok, _} = ActivityPub.Object.insert(add_activity_data, false, local_user.id)

      # Clear cache so the next lookup hits the DB
      ActivityPub.Actor.invalidate_cache(local_actor)

      # Must return the local actor, not the Add activity
      assert {:ok, actor} = ActivityPub.Actor.get_cached(pointer: local_user.id)
      assert actor.ap_id == local_actor.ap_id
      refute actor.ap_id =~ "relay.example.com"
    end

    test "incoming Add activity with local user as object does not corrupt actor pointer lookup" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      # Store the Add activity in ap_objects (giving it a UUID) so that handle_activity_with
      # in incoming.ex has a real activity_id on which to run its pointer_id update.
      # This exercises the `Enums.id(activity) || Enums.id(object)` fallback path.
      {:ok, add_ap_object} =
        ActivityPub.Object.insert(
          %{
            "id" => @relay_add_id,
            "type" => "Add",
            "actor" => @relay_actor,
            "object" => local_actor.ap_id
          },
          false
        )

      ActivityPub.Actor.invalidate_cache(local_actor)
      Bonfire.Federate.ActivityPub.Incoming.receive_activity(add_ap_object)

      # Local user must still be resolvable by pointer after the incoming activity
      assert {:ok, actor} = ActivityPub.Actor.get_cached(pointer: local_user.id)
      assert actor.ap_id == local_actor.ap_id
      refute actor.ap_id =~ "relay.example.com"
    end

    test "outgoing follow has correct actor after relay Add activity corrupts the pointer cache" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      # Set up the remote user to follow
      {:ok, _ap_followed} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, followed} = Bonfire.Me.Users.by_ap_id(@remote_actor)

      # Directly inject the DB corruption: Add activity stored with local user's pointer_id.
      # This simulates what happens in production after tags.pub sends an Add activity
      # and incoming.ex writes the wrong pointer_id.
      {:ok, _} =
        ActivityPub.Object.insert(
          %{
            "id" => @relay_add_id,
            "type" => "Add",
            "actor" => @relay_actor,
            "object" => local_actor.ap_id
          },
          false,
          local_user.id
        )

      ActivityPub.Actor.invalidate_cache(local_actor)

      # Local user follows the remote user — the Follow activity's actor must be the local
      # user's AP URL, not the relay's Add activity URL
      {:ok, follow} = Follows.follow(local_user, followed)
      {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

      assert follow_activity.data["actor"] == local_actor.ap_id
      refute follow_activity.data["actor"] =~ "relay.example.com"
    end
  end

  describe "RepairCorruptedActorPointers data migration" do
    test "shape A: nulls pointer_id on non-actor AP objects pointing to local users" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      # Reproduce shape A corruption: Add activity stored with pointer_id = local user ULID.
      # This is what the old incoming.ex `Enums.id(activity) || Enums.id(object)` fallback
      # produced when the activity's object was the local user's AP actor.
      {:ok, add_ap_object} =
        ActivityPub.Object.insert(
          %{
            "id" => @relay_add_id,
            "type" => "Add",
            "actor" => @relay_actor,
            "object" => local_actor.ap_id
          },
          false
        )

      Repatch.patch(ActivityPub.Object, :update_existing, fn _id, attrs ->
        # Simulate old buggy fallback: always writes to the Add activity row but with
        # the user's ULID as pointer_id (as if ap_receive_activity returned the user)
        Repatch.real(ActivityPub.Object, :update_existing, [
          add_ap_object.id,
          Map.put(attrs, :pointer_id, local_user.id)
        ])
      end)

      Bonfire.Federate.ActivityPub.Incoming.receive_activity(add_ap_object)

      # Confirm shape A corruption exists
      corrupted = Bonfire.Common.Repo.get!(ActivityPub.Object, add_ap_object.id)
      assert corrupted.pointer_id == local_user.id

      RepairCorruptedActorPointers.run()

      repaired = Bonfire.Common.Repo.get!(ActivityPub.Object, add_ap_object.id)
      assert is_nil(repaired.pointer_id)

      # Local user must still be resolvable by pointer
      assert {:ok, actor} = ActivityPub.Actor.get_cached(pointer: local_user.id)
      assert actor.ap_id == local_actor.ap_id
    end

    test "shape B: restores pointer_id on local user's AP actor when clobbered" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      # Ensure the local user's AP actor exists as an ap_objects row with correct pointer_id.
      # In production this row is created when the actor is first published; in tests we
      # create it explicitly so we can observe it being corrupted and then repaired.
      {:ok, user_ap_obj} =
        ActivityPub.Object.insert(local_actor.data, true, local_user.id)

      assert user_ap_obj.pointer_id == local_user.id

      # Reproduce shape B corruption directly: the old buggy fallback called
      # update_existing(Enums.id(object), ...) — i.e. the user's AP actor UUID —
      # instead of the activity's UUID, clobbering the user's pointer_id.
      # Use another real user's ID as the "wrong" pointer_id (FK constraint requires a real ULID).
      other_user = fake_user!()
      ActivityPub.Object.update_existing(user_ap_obj.id, %{pointer_id: other_user.id})

      # Confirm shape B corruption: user's AP actor now has wrong pointer_id
      clobbered = Bonfire.Common.Repo.get!(ActivityPub.Object, user_ap_obj.id)
      refute clobbered.pointer_id == local_user.id

      RepairCorruptedActorPointers.run()

      restored = Bonfire.Common.Repo.get!(ActivityPub.Object, user_ap_obj.id)
      assert restored.pointer_id == local_user.id
    end

    test "repair does not affect untouched local users, remote actors, or remote notes" do
      # Two unrelated local users
      local_user1 = fake_user!()
      local_user2 = fake_user!()
      {:ok, local_actor1} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user1.id)
      {:ok, local_actor2} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user2.id)

      # Remote actor (Person) — fetch so an ap_objects row with pointer_id exists
      {:ok, _remote_ap} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      {:ok, remote_ap_obj_before} = ActivityPub.Object.get_cached(ap_id: @remote_actor)

      # Remote note inserted raw — no pointer_id (never processed through federation pipeline)
      {:ok, remote_note_raw} =
        ActivityPub.Object.insert(
          %{
            "id" => @remote_instance <> "/notes/raw",
            "type" => "Note",
            "content" => "hello raw",
            "attributedTo" => @remote_actor
          },
          false
        )

      # Remote note processed through receive_activity — gets a real pointer_id to a post
      {:ok, remote_ap} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      params = remote_activity_json(remote_ap, [ActivityPub.Config.public_uri()])
      {:ok, create_activity} = ActivityPub.create(params)
      {:ok, _post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(create_activity)

      {:ok, remote_note_processed} =
        ActivityPub.Object.get_cached(ap_id: create_activity.object.data["id"])

      assert not is_nil(remote_note_processed.pointer_id)

      # Inject shape A corruption on local_user1 only
      {:ok, _} =
        ActivityPub.Object.insert(
          %{
            "id" => @relay_add_id,
            "type" => "Add",
            "actor" => @relay_actor,
            "object" => local_actor1.ap_id
          },
          false,
          local_user1.id
        )

      RepairCorruptedActorPointers.run()

      # Both local users must still be resolvable by pointer
      assert {:ok, actor1} = ActivityPub.Actor.get_cached(pointer: local_user1.id)
      assert actor1.ap_id == local_actor1.ap_id

      assert {:ok, actor2} = ActivityPub.Actor.get_cached(pointer: local_user2.id)
      assert actor2.ap_id == local_actor2.ap_id

      # Remote actor's AP object pointer_id must be untouched
      remote_ap_obj_after = Bonfire.Common.Repo.get!(ActivityPub.Object, remote_ap_obj_before.id)
      assert remote_ap_obj_after.pointer_id == remote_user.id

      # Raw remote note (no pointer_id) must still have no pointer_id
      raw_note_after = Bonfire.Common.Repo.get!(ActivityPub.Object, remote_note_raw.id)
      assert is_nil(raw_note_after.pointer_id)

      # Processed remote note (pointer_id → post) must be untouched
      processed_note_after =
        Bonfire.Common.Repo.get!(ActivityPub.Object, remote_note_processed.id)

      assert processed_note_after.pointer_id == remote_note_processed.pointer_id
    end
  end

  describe "PeerTube attributedTo list does not fall back to service character" do
    test "activity_character with attributedTo [Group, Person] list resolves the Person" do
      video_data = %{
        "id" => @peertube_video_id,
        "type" => "Video",
        "attributedTo" => [
          %{"type" => "Group", "id" => @peertube_group},
          %{"type" => "Person", "id" => @peertube_person}
        ]
      }

      assert {:ok, character} =
               Bonfire.Federate.ActivityPub.AdapterUtils.activity_character(video_data)

      service = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_create_service_character()

      # Must resolve to the Person, not the service character
      refute character.id == service.id
      assert character.peered.canonical_uri == @peertube_person
    end
  end
end
