defmodule Bonfire.Federate.ActivityPub.RelayActorCorruptionTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Graph.Follows

  import Tesla.Mock

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
