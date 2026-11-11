defmodule Bonfire.Federate.ActivityPub.GroupMembershipOutgoingTest do
  @moduledoc """
  A local person joining, and leaving, a group hosted elsewhere.

  Pressing Join means join AND follow, so both go out: Lemmy acts on the `Follow` (following IS joining there) and ignores the `Join`, while Mobilizon makes them a member from the `Join` and a follower from the `Follow`. Sending both is what works for both families without detecting which software hosts the group.

  Until the group answers, whatever it declares, they wait: a pending join request, and no membership. The group's `Accept(Join)` or `Reject(Join)` then settles it (and where following is joining, the answer to the `Follow` does). A group hosted here that is open still admits at once.
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

  defp remote_group(openness) when is_binary(openness),
    do: remote_group(%{"openness" => openness})

  defp remote_group(%{} = declares) do
    group_json =
      APSimulate.actor_json(@remote_group, "cooks", Map.put(declares, "type", "Group"))

    # served too, since sending re-fetches the actor, and a refetch that states no `openness` re-mirrors the group as open
    mock(fn
      %{method: :get, url: @remote_group} ->
        json(group_json)

      %{method: :get, url: @stranger} ->
        json(APSimulate.actor_json(@stranger, "bakers", %{"type" => "Group"}))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
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
    do: Bonfire.Social.Requests.requested?(user, Bonfire.Boundaries.Verbs.get_id!(:join), group)

  # how each thing they did themself reads in their own notifications
  defp notified_as(user) do
    %{edges: edges} =
      Bonfire.Social.FeedLoader.feed(:notifications, current_user: user, preload: false)

    edges
    |> Enum.map(& &1.activity)
    |> Enum.filter(&(&1.subject_id == id(user)))
    |> Enum.map(&Bonfire.Social.Activities.experienced_as(&1, id(user)))
  end

  # what is put in their notifications feed, read where it is published: a feed read hides what they may not read
  defp own_notification_rows(user) do
    feed_id = Bonfire.Social.Feeds.feed_id(:notifications, user)

    Bonfire.Data.Social.FeedPublish
    |> Ecto.Query.where(feed_id: ^feed_id)
    |> repo().all()
  end

  describe "joining an open remote group" do
    test "sends a Join and a Follow as them, and waits for the group's Accept to make them a member" do
      user = fake_user!()
      group = remote_group("open")

      assert {:ok, %{requested: true}} = Categories.join_and_follow_group(user, group)

      assert [join] = sent("Join", user), "the group never hears they joined"
      assert [_] = sent("Follow", user), "a peer where following is joining hears nothing"
      assert join_requested?(user, group)
      refute Categories.member?(user, group), "the group has not agreed yet"

      # their own pending join stays a record, and is not put in their own notifications: they hear when it is granted
      assert [] == own_notification_rows(user), "a pending join is in their own notifications"

      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join))

      assert Categories.member?(user, group)
      refute join_requested?(user, group), "the request was answered, so it is no longer pending"
      assert [_] = sent("Join", user), "being accepted is not joining again"

      assert notified_as(user) == [],
             "an open group was always going to let them in, so the Accept tells them nothing new"
    end

    # follow IS join there (no `members` collection), so it is the Accept of the Follow that admits them
    test "where following is joining, the Accept of the Follow makes them a member" do
      user = fake_user!()
      group = remote_group("open")
      assert {:ok, _} = Categories.join_and_follow_group(user, group)
      assert [follow] = sent("Follow", user)
      refute Categories.member?(user, group), "the group has not agreed yet"

      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", follow))

      assert Categories.member?(user, group), "the group will never answer the Join"
      refute join_requested?(user, group)
    end

    test "pressing Join again while waiting sends nothing more and asks once" do
      user = fake_user!()
      group = remote_group("open")
      assert {:ok, %{requested: true}} = Categories.join_and_follow_group(user, group)

      assert {:ok, %{requested: true}} = Categories.join_and_follow_group(user, group)

      assert [_] = sent("Join", user)
      assert join_requested?(user, group)
      refute Categories.member?(user, group)
    end

    test "a group hosted here that is open still admits at once" do
      creator = fake_user!()
      group = Bonfire.Classify.Simulate.fake_group!(creator)

      assert :ok =
               Bonfire.Classify.Boundaries.replace(group, creator, %{
                 membership: "open",
                 visibility: "global",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      user = fake_user!()
      assert {:ok, _} = Categories.join_group(user, group)

      assert Categories.member?(user, group)
      refute join_requested?(user, group)
    end

    test "then leaving sends a Leave" do
      user = fake_user!()
      group = remote_group("open")
      assert {:ok, _} = Categories.join_group(user, group)
      assert [join] = sent("Join", user)
      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join))
      assert Categories.member?(user, group), "control: a member"

      assert {:ok, _} = Categories.leave_group(user, group)

      refute Categories.member?(user, group)
      assert [_] = sent("Leave", user)
    end

    # what goes on the wire, not what we store: preparing it for sending used to swap the group's id for its whole cached actor document, as it once did for `Follow`, and implementations type the object as a link (seen live against Lemmy 1.0, 3 October)
    test "the Join and the Leave reference the group by its id" do
      user = fake_user!()
      group = remote_group("open")
      assert {:ok, _} = Categories.join_group(user, group)
      assert {:ok, _} = Categories.leave_group(user, group)

      for type <- ["Join", "Leave"] do
        assert [activity] = sent(type, user)
        assert {:ok, json} = Transformer.prepare_outgoing(activity.data)

        assert json["object"] == @remote_group,
               "the #{type} embeds the group instead of naming it: #{inspect(json["object"])}"
      end
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

      assert notified_as(user) == [:join],
             "they asked, and the group's Accept is the answer, so they are told once, as a member"
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

  # The answered `Join` stays stored after they leave, and is found by its id alone, so an `Accept` may only settle a join still waiting here. Late, or sent by someone with an old `Join` of theirs, it must not put back someone who left
  describe "the group's Accept of a Join" do
    for openness <- ["open", "moderated"] do
      test "after they left does not make them a member again (#{openness} group)" do
        user = fake_user!()
        group = remote_group(unquote(openness))
        assert {:ok, _} = Categories.join_group(user, group)
        assert [join] = sent("Join", user)

        assert {:ok, _} = Categories.leave_group(user, group)
        assert [_] = sent("Leave", user), "control: the group was told they left"
        refute Categories.member?(user, group), "control: they left"
        refute join_requested?(user, group)

        assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join)),
               "the Accept never reached the handler, so this test proves nothing"

        refute Categories.member?(user, group), "a late Accept put back someone who left"
      end
    end

    # once the Accept has made them a member and cleared the request, a second one (a retry, or a group announcing it again) has nothing to settle: it must leave them a member
    test "arriving a second time for an open group keeps them a member" do
      user = fake_user!()
      group = remote_group("open")
      assert {:ok, _} = Categories.join_group(user, group)
      assert [join] = sent("Join", user)
      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join))
      assert Categories.member?(user, group), "control: the first Accept admitted them"
      refute join_requested?(user, group), "and cleared the request for the next to settle"

      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join))

      assert Categories.member?(user, group)
    end
  end

  # Lemmy, PieFed, Mbin and NodeBB never answer a `Join`, since following is joining there. Their actors declare no `members` collection, which is how we tell them apart from a group that answers joins itself. Not `openness`: we fill that in on storage from `manuallyApprovesFollowers` (`Transformer.fix_openness/1`), so every stored group that reviews followers has one
  describe "joining a remote group where following is joining, which reviews followers" do
    @follow_is_join %{"manuallyApprovesFollowers" => true}

    test "its Accept of the Follow also makes them a member" do
      user = fake_user!()
      group = remote_group(@follow_is_join)
      assert {:ok, _} = Categories.join_and_follow_group(user, group)
      assert join_requested?(user, group)
      assert [follow] = sent("Follow", user)

      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", follow))

      assert Categories.member?(user, group), "the group will never answer the Join"
      refute join_requested?(user, group)
    end

    test "its Reject of the Follow drops the join request" do
      user = fake_user!()
      group = remote_group(@follow_is_join)
      assert {:ok, _} = Categories.join_and_follow_group(user, group)
      assert [follow] = sent("Follow", user)

      Transformer.handle_incoming(answer("Reject", follow))

      refute Categories.member?(user, group)

      refute join_requested?(user, group),
             "left pending forever, since no answer to the Join will come"
    end

    # following without pressing Join is only following, even where the group itself makes no difference
    test "accepting a Follow nobody asked to join with makes nobody a member" do
      user = fake_user!()
      group = remote_group(@follow_is_join)
      assert {:ok, _} = Categories.follow_group(user, group)
      assert [follow] = sent("Follow", user)

      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", follow))

      assert Bonfire.Social.Graph.Follows.following?(user, group),
             "the Accept never landed, so this test proves nothing"

      refute Categories.member?(user, group)
    end
  end

  # a group that said yes can take it back (a removed member): honoured, and not answered, since the group already knows
  describe "the group's Reject after it said yes" do
    test "of an accepted Join removes the member, and no Leave goes out" do
      user = fake_user!()
      group = remote_group("moderated")
      assert {:ok, _} = Categories.join_group(user, group)
      assert [join] = sent("Join", user)
      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", join))
      assert Categories.member?(user, group), "control: a member"

      Transformer.handle_incoming(answer("Reject", join))

      refute Categories.member?(user, group)
      assert sent("Leave", user) == []
    end

    test "of the Follow where following is joining removes the membership and the follow" do
      user = fake_user!()
      group = remote_group(@follow_is_join)
      assert {:ok, _} = Categories.join_and_follow_group(user, group)
      assert [follow] = sent("Follow", user)
      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", follow))
      assert Categories.member?(user, group), "control: a member"
      assert Bonfire.Social.Graph.Follows.following?(user, group), "control: following"

      Transformer.handle_incoming(answer("Reject", follow))

      refute Bonfire.Social.Graph.Follows.following?(user, group)
      refute Categories.member?(user, group)
    end

    # Lemmy and Mbin embed the Follow they answer
    test "of the Follow, embedded, drops a pending join and the follow request" do
      user = fake_user!()
      group = remote_group(@follow_is_join)
      assert {:ok, _} = Categories.join_and_follow_group(user, group)
      assert [%{data: %{"id" => follow_id}} = follow] = sent("Follow", user)
      assert join_requested?(user, group), "control: a join waits"

      embedded = answer("Reject", follow) |> Map.put("object", follow.data)
      assert follow.data["id"] == follow_id
      Transformer.handle_incoming(embedded)

      refute join_requested?(user, group)
      refute Bonfire.Social.Requests.requested?(user, Bonfire.Data.Social.Follow, group)
      refute Categories.member?(user, group)
    end
  end

  @remote_person "https://lemmy.local/u/joiner"

  describe "removing a remote member of a group here" do
    setup do
      mock(fn
        %{method: :get, url: @remote_person} ->
          json(APSimulate.actor_json(@remote_person, "joiner"))

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}
      end)

      creator = fake_user!()
      group = Bonfire.Classify.Simulate.fake_group!(creator)

      assert :ok =
               Bonfire.Classify.Boundaries.replace(group, creator, %{
                 membership: "open",
                 visibility: "global",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

      %{creator: creator, group: group, group_ap_id: actor.ap_id}
    end

    defp from_remote(type, group_ap_id) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => type,
        "id" =>
          "#{@remote_person}/#{String.downcase(type)}/#{System.unique_integer([:positive])}",
        "actor" => @remote_person,
        "object" => group_ap_id,
        "to" => [group_ap_id]
      }
    end

    # the `Reject`s the group sent for what the remote person sent, by the type of what is rejected
    defp rejects_of(group_ap_id) do
      ActivityPub.Object
      |> repo().all()
      |> Enum.filter(fn %{local: local, data: data} ->
        local and data["type"] == "Reject" and data["actor"] == group_ap_id and
          is_map(data["object"]) and data["object"]["actor"] == @remote_person
      end)
      |> Enum.map(& &1.data["object"]["type"])
      |> Enum.sort()
    end

    test "rejects their Follow and their Join, so their server stops treating them as one", %{
      creator: creator,
      group: group,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(from_remote("Follow", group_ap_id))
      assert {:ok, _} = Transformer.handle_incoming(from_remote("Join", group_ap_id))

      {:ok, user} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(@remote_person)

      assert Categories.member?(user, group), "control: a member"
      assert rejects_of(group_ap_id) == [], "control: nothing rejected yet"

      assert {:ok, %{member: false}} = Categories.remove_member(creator, group, id(user))

      assert rejects_of(group_ap_id) == ["Follow", "Join"]
      refute Categories.member?(user, group)
      refute Bonfire.Social.Graph.Follows.following?(user, group)
    end

    test "sends nothing for a local member", %{
      creator: creator,
      group: group,
      group_ap_id: group_ap_id
    } do
      member = fake_user!()
      {:ok, _} = Categories.join_and_follow_group(member, group, skip_boundary_check: true)
      assert Categories.member?(member, group), "control: a member"

      assert {:ok, _} = Categories.remove_member(creator, group, id(member))

      refute Categories.member?(member, group)

      assert ActivityPub.Object
             |> repo().all()
             |> Enum.filter(
               &(&1.local and &1.data["type"] == "Reject" and &1.data["actor"] == group_ap_id)
             ) ==
               []
    end
  end

  describe "joining a remote group that answers joins itself" do
    # Smithereen declares only `members`; Mobilizon and Bonfire declare `openness` too
    for {software, declares} <- [
          {"Smithereen", %{"members" => "#{@remote_group}/members"}},
          {"Mobilizon or Bonfire",
           %{"members" => "#{@remote_group}/members", "openness" => "moderated"}}
        ] do
      @declares Map.put(declares, "manuallyApprovesFollowers", true)

      test "its Accept of the Follow leaves the join pending (#{software}-shaped)" do
        user = fake_user!()
        group = remote_group(@declares)
        assert {:ok, _} = Categories.join_and_follow_group(user, group)
        assert join_requested?(user, group)
        assert [follow] = sent("Follow", user)

        assert {:ok, _} = Transformer.handle_incoming(answer("Accept", follow))

        assert Bonfire.Social.Graph.Follows.following?(user, group),
               "the Accept never landed, so this test proves nothing"

        refute Categories.member?(user, group), "accepting a follow there is not accepting a join"
        assert join_requested?(user, group)
      end
    end
  end
end
