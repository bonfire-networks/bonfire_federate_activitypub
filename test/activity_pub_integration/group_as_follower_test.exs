defmodule Bonfire.Federate.ActivityPub.GroupAsFollowerTest do
  @moduledoc """
  A group can follow a remote actor, with the GROUP as the `actor` of the `Follow`.

  This is what enabling a bridge takes. Bridgy Fed offers two ways in (`fed.brid.gy/docs`): log in on their site, or **follow `@bsky.brid.gy@bsky.brid.gy` and accept its follow back**. While we serve the login side (`bonfire_open_id` answers `/api/v1/apps`, `/oauth/authorize` and `/oauth/token`, and our actors advertise all three), logging in authenticates a PERSON and bridges that account; saying "bridge this group I moderate" through it is the authority question `snarfed/bridgy-fed#372` leaves open. So the follow route is the one available to a group, and it makes the group act twice: once as the follower, once as the actor accepting the follow back. Neither is something a group has had to do before, since following has always been what its members do.

  The federation half is already type-agnostic: `Follows.ap_publish_activity/3` resolves the follower with `ActivityPub.Actor.get_cached(pointer: subject)`, which answers for any actor. What this pins is the LOCAL half, where a group has to survive a path built for people: `Follows.follow/3` preloads `[:character, :peered]` on the follower and boundary-checks it as a SUBJECT.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias Bonfire.Social.Graph.Follows

  @remote_actor "https://mocked.local/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} -> json(APSimulate.actor_json(@remote_actor))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  test "a group can follow a remote actor, sending the Follow as itself" do
    creator = fake_user!()

    group =
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    assert {:ok, remote} = APSimulate.fake_remote_user()

    assert {:ok, _} = Follows.follow(group, remote, skip_boundary_check: true)

    # following a REMOTE actor is a pending request locally until they `Accept`, which is the bridge dance itself, so what matters here is the `Follow` we put on the wire rather than local state
    assert Follows.requested?(group, remote),
           "the group, not its creator, is the one asking to follow"

    assert {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group)
    assert {:ok, %{ap_id: remote_ap_id}} = ActivityPub.Actor.get_cached(pointer: remote)

    assert %{data: %{"actor" => actor, "object" => object}} =
             ActivityPub.Object.get_activity_for_object_ap_id(remote_ap_id, "Follow"),
           "enabling a bridge is a Follow the GROUP sends, so one has to exist on the wire"

    assert actor == group_ap_id,
           "if the creator is the actor, the bridge bridges the person rather than the group"

    assert object == remote_ap_id
  end

  # The other half of the same dance: the bridge follows back, and its docs are explicit that the follow has to be ACCEPTED or nothing flows. For an open group that should need no human, since anyone may follow it.
  test "an incoming Follow of an open group is accepted" do
    creator = fake_user!()

    group =
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    assert {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Follow",
               "id" => "#{@remote_actor}/follows/group",
               "actor" => @remote_actor,
               "object" => group_ap_id
             })

    assert %{data: %{"type" => "Accept"}} =
             ActivityPub.Object.get_activity_for_object_ap_id(
               "#{@remote_actor}/follows/group",
               "Accept"
             ),
           "an open group anyone may follow has nobody to ask, so a follow of it should be answered without one"
  end
end
