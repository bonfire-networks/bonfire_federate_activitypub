defmodule Bonfire.Federate.ActivityPub.GroupMembershipIncomingTest do
  @moduledoc """
  Remote actors joining, following and leaving one of our groups.

  A `Follow` is ambiguous and nothing in the message resolves it: from Lemmy it means "join", from Mobilizon it means only "subscribe", and Mobilizon sends `Join` for the other. So the rule is to always do the act you were sent, and add the other half only for an actor who was not already following. A `Follow` therefore ALWAYS produces a follow and SOMETIMES also membership, never a join alone.

  Routing is by `{activity_type, object_type}`, which ingest tries before `activity_type` alone, so `Categories` claiming `{"Follow", "Group"}` takes the Group case while `Follows`' plain `"Follow"` keeps handling everyone else.

  In-process rather than through a peer: both halves are ours, so what a second instance would add is the wire, not the mapping. The dance tests come after.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer

  @remote_actor "https://lemmy.local/u/joiner"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(APSimulate.actor_json(@remote_actor, "joiner"))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    %{creator: creator, group: group, group_ap_id: actor.ap_id}
  end

  defp membership_activity(type, group_ap_id, actor \\ @remote_actor) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => type,
      "id" => "#{actor}/#{String.downcase(type)}/#{System.unique_integer([:positive])}",
      "actor" => actor,
      "object" => group_ap_id,
      "to" => [group_ap_id]
    }
  end

  defp undo(activity, actor \\ @remote_actor) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Undo",
      "id" => "#{activity["id"]}/undo",
      "actor" => actor,
      "object" => activity,
      "to" => activity["to"]
    }
  end

  defp remote_user do
    {:ok, user} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(@remote_actor)

    user
  end

  describe "an incoming Follow" do
    test "from an actor with no relationship makes them a member and a follower", %{
      group: group,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Follow", group_ap_id))

      user = remote_user()

      assert Categories.member?(user, group)
      assert Bonfire.Social.Graph.Follows.following?(user, group)
    end

    # Lemmy re-sends its `Follow` periodically to keep a subscription alive, so a repeat has to be free rather than an error the sender sees, and must not widen anything.
    test "repeated leaves exactly one follow and no upgrade", %{
      group: group,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Follow", group_ap_id))
      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Follow", group_ap_id))

      user = remote_user()

      assert Bonfire.Social.Graph.Follows.following?(user, group)
      assert Categories.member?(user, group)
    end

    # Someone already subscribed chose that; a `Follow` arriving again is the same choice restated, not a request for more.
    test "from an existing follower adds no membership", %{group: group, group_ap_id: group_ap_id} do
      user = remote_user()

      assert {:ok, _} =
               Bonfire.Social.Graph.Follows.follow(user, group, skip_boundary_check: true)

      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Follow", group_ap_id))

      assert Bonfire.Social.Graph.Follows.following?(user, group)
      refute Categories.member?(user, group)
    end
  end

  describe "an incoming Join" do
    # A peer that sends `Join` HAS both verbs, so it will send `Follow` separately when it wants the feed. Reading its `Join` as "join and follow" invents a subscription it did not ask for.
    test "makes them a member without a follow", %{group: group, group_ap_id: group_ap_id} do
      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Join", group_ap_id))

      user = remote_user()

      assert Categories.member?(user, group)
      refute Bonfire.Social.Graph.Follows.following?(user, group)
    end
  end

  describe "an incoming Leave" do
    test "drops membership and keeps the follow", %{group: group, group_ap_id: group_ap_id} do
      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Follow", group_ap_id))

      user = remote_user()
      assert Categories.member?(user, group)

      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Leave", group_ap_id))

      refute Categories.member?(user, group)

      assert Bonfire.Social.Graph.Follows.following?(user, group),
             "leaving a group is not unsubscribing from it, which is what lets someone keep reading after they go"
    end
  end

  # `Undo{Follow}` is ambiguous in exactly the way `Follow` is, and the two peer families need opposite answers from the same message. Lemmy has no `Leave` at all, so `Undo{Follow}` is the only way its users can leave; Mobilizon distinguishes, so for its users the same message must be unsubscribing and nothing more. Reading every peer as one or the other strands the other family.
  #
  # Both paths are pinned here, and what resolves them is recording how the MEMBERSHIP was created: one that came from a `Follow` is linked to it and goes when that `Follow` is undone, one that came from a `Join` is linked to the `Join` instead, so an `Undo{Follow}` finds nothing to remove and only the subscription stops.
  describe "an incoming Undo of a Follow, from a peer that distinguishes (Mobilizon-shaped)" do
    # The story the whole separation exists for: join a group, stop reading its feed, stay a member.
    test "stops the follow and leaves membership alone", %{group: group, group_ap_id: group_ap_id} do
      # bind it, so the activity that gets undone is the one that was sent: `membership_activity/3` mints a fresh id each call, and the mechanism under test resolves the undo by that id
      follow = membership_activity("Follow", group_ap_id)

      assert {:ok, _} = Transformer.handle_incoming(membership_activity("Join", group_ap_id))
      assert {:ok, _} = Transformer.handle_incoming(follow)

      user = remote_user()
      assert Categories.member?(user, group)
      assert Bonfire.Social.Graph.Follows.following?(user, group)

      assert {:ok, _} = Transformer.handle_incoming(undo(follow))

      refute Bonfire.Social.Graph.Follows.following?(user, group)

      assert Categories.member?(user, group),
             "unsubscribing from a group's feed is not leaving it, which is what `Leave` is for"
    end
  end

  describe "an incoming Undo of a Follow, from a peer that does not (Lemmy-shaped)" do
    test "drops the membership too, since the follow is how they joined", %{
      group: group,
      group_ap_id: group_ap_id
    } do
      follow = membership_activity("Follow", group_ap_id)

      assert {:ok, _} = Transformer.handle_incoming(follow)

      user = remote_user()
      assert Categories.member?(user, group), "the control: following is how this peer joins"

      assert {:ok, _} = Transformer.handle_incoming(undo(follow))

      refute Bonfire.Social.Graph.Follows.following?(user, group)

      refute Categories.member?(user, group),
             "a peer with no `Leave` to send has only this to leave with, so membership created by the follow has to go with it"
    end
  end

  describe "an invite-only group" do
    setup %{creator: creator, group: group} do
      assert :ok =
               Bonfire.Classify.Boundaries.apply(group, creator, %{
                 membership: "invite_only",
                 visibility: "global",
                 participation: "group_members",
                 default_content_visibility: "public"
               })

      :ok
    end

    # Decided 2026-09-08: `Reject` would be more honest about the outcome, but it resets the sender's button and invites the same request again, and silence is also what Mobilizon does. Only meaningful paired with the open-group cases above passing, since "refused" and "the handler never ran" look identical from here.
    test "discards an incoming Join, leaving no membership and no request", %{
      group: group,
      group_ap_id: group_ap_id
    } do
      Transformer.handle_incoming(membership_activity("Join", group_ap_id))

      user = remote_user()

      refute Categories.member?(user, group)

      refute Bonfire.Social.Requests.requested?(
               user,
               Bonfire.Boundaries.Verbs.get_id!(:join),
               group
             )
    end
  end
end
