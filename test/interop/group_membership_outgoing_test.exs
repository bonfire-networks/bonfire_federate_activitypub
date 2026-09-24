defmodule Bonfire.Federate.ActivityPub.GroupMembershipOutgoingTest do
  @moduledoc """
  A local person joining, and leaving, a group hosted elsewhere.

  Pressing Join means join AND follow, so both go out: Lemmy acts on the `Follow` (following IS joining there) and ignores the `Join`, while Mobilizon makes them a member from the `Join` and a follower from the `Follow`. Sending both is what works for both families without detecting which software hosts the group.

  Until the group answers, our mirror decides from what the group declares: an `open` one makes them a member at once, an `on_request` one leaves a pending join request. The group's `Accept(Join)` or `Reject(Join)` then settles it.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer

  @remote_group "https://mocked.local/groups/cooks"
  # another GROUP: a person answering is refused anyway, because the handler only acts for a group
  @stranger "https://other.local/groups/bakers"

  setup do
    mock(fn
      %{method: :get, url: @remote_group} ->
        json(APSimulate.actor_json(@remote_group, "cooks", %{"type" => "Group"}))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  defp remote_group(openness) do
    group_json =
      APSimulate.actor_json(@remote_group, "cooks", %{"type" => "Group", "openness" => openness})

    # served too, since sending re-fetches the actor, and a refetch that states no `openness` re-mirrors the group as open
    mock(fn
      %{method: :get, url: @remote_group} -> json(group_json)
      %{method: :get, url: @stranger} ->
        json(APSimulate.actor_json(@stranger, "bakers", %{"type" => "Group"}))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, group} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(group_json)

    {:ok, group} = Categories.get(id(group), skip_boundary_check: true)
    group
  end

  # what went out as this person about the remote group
  defp sent(type, user) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)

    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(
      &(&1.local and &1.data["type"] == type and &1.data["actor"] == actor.ap_id and
          ActivityPub.Object.get_ap_id(&1.data["object"]) == @remote_group)
    )
  end

  defp answer(type, %{data: %{"id" => join_id, "actor" => joiner}}, from \\ @remote_group) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => type,
      "id" => "#{from}/#{String.downcase(type)}/#{System.unique_integer([:positive])}",
      "actor" => from,
      "object" => join_id,
      "to" => [joiner]
    }
  end

  defp join_requested?(user, group),
    do:
      Bonfire.Social.Requests.requested?(user, Bonfire.Boundaries.Verbs.get_id!(:join), group)

  describe "joining an open remote group" do
    test "sends a Join and a Follow as them, and makes them a member" do
      user = fake_user!()
      group = remote_group("open")

      assert {:ok, _} = Categories.join_and_follow_group(user, group)

      assert Categories.member?(user, group)
      assert [_] = sent("Join", user), "the group never hears they joined"
      assert [_] = sent("Follow", user), "a peer where following is joining hears nothing"
    end

    test "then leaving sends a Leave" do
      user = fake_user!()
      group = remote_group("open")
      assert {:ok, _} = Categories.join_group(user, group)

      assert {:ok, _} = Categories.leave_group(user, group)

      refute Categories.member?(user, group)
      assert [_] = sent("Leave", user)
    end

    # the pair of the test above: a `Leave` from someone the group never had is noise at best
    test "leaving one you never joined sends nothing" do
      user = fake_user!()
      group = remote_group("open")

      assert {:ok, _} = Categories.leave_group(user, group)

      assert sent("Leave", user) == []
    end
  end

  describe "joining a remote group that reviews joins" do
    test "sends a Join and waits for the answer" do
      user = fake_user!()
      group = remote_group("moderated")

      assert {:ok, _} = Categories.join_and_follow_group(user, group)

      assert [_] = sent("Join", user)
      refute Categories.member?(user, group), "the group has not answered yet"
      assert join_requested?(user, group)
    end

    test "its Accept makes them a member" do
      user = fake_user!()
      group = remote_group("moderated")
      assert {:ok, _} = Categories.join_group(user, group)
      assert [join] = sent("Join", user)

      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join))

      assert Categories.member?(user, group)
      refute join_requested?(user, group), "the request was answered, so it is no longer pending"

      assert [_] = sent("Join", user),
             "being accepted is not joining again, so nothing more goes out"
    end

    # the answered `Join` is found by its id alone, so only the group it was sent to may settle it. The Accept test above is the positive control
    test "an Accept from any group but the one asked is refused" do
      user = fake_user!()
      group = remote_group("moderated")

      # known here, as any group someone has come across would be: an `Accept` from an actor we have never seen does not get this far
      {:ok, stranger} =
        Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(
          APSimulate.actor_json(@stranger, "bakers", %{"type" => "Group"})
        )

      assert {:ok, _} = Categories.join_group(user, group)
      assert [join] = sent("Join", user)

      Transformer.handle_incoming(answer("Accept", join, @stranger))

      refute Categories.member?(user, stranger),
             "a group they never asked to join admitted them by answering someone else's Join"

      refute Categories.member?(user, group)
      assert join_requested?(user, group), "the request still waits for the group's own answer"
    end

    test "its Reject drops the request and makes no member" do
      user = fake_user!()
      group = remote_group("moderated")
      assert {:ok, _} = Categories.join_group(user, group)
      assert [join] = sent("Join", user)

      Transformer.handle_incoming(answer("Reject", join))

      refute Categories.member?(user, group)
      refute join_requested?(user, group)
      assert sent("Leave", user) == [], "the group said no, so there is nothing to leave"
    end
  end
end
