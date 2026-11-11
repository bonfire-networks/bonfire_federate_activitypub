defmodule Bonfire.Federate.ActivityPub.GroupMembersFederationTest do
  @moduledoc """
  A group hosted here tells the servers of its remote members about changes to who is in it, as Mobilizon does for its own: the activity goes `to` the group's members collection (which nothing on our side expands), and the remote members are in `bcc`, so each of their servers hears of it once. Without a remote member to tell, nothing more is sent than before.

  The first remote member here is a Mobilizon person (`Testing.MobilizonShapes`) whose `Join` was admitted.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias Bonfire.Federate.ActivityPub.Testing.MobilizonShapes, as: Mobilizon

  @lemmy "https://lemmy.local/u/joiner"

  setup do
    mock(fn
      %{method: :get, url: @lemmy} ->
        json(APSimulate.actor_json(@lemmy, "joiner"))

      %{method: :get, url: "https://mobilizon.local/@member" <> n = url} ->
        json(APSimulate.actor_json(url, "member" <> n))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    ctx = %{
      creator: creator,
      group: group,
      group_ap_id: actor.ap_id,
      members_url: ActivityPub.Utils.collection_ap_id("members", id(group))
    }

    # the first remote member: a Mobilizon person, who joined, and followed too (Mobilizon sends the two apart)
    mobilizon_joins(ctx, 1)

    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Follow",
               "id" => "#{Mobilizon.person(1)}/follow/1",
               "actor" => Mobilizon.person(1),
               "object" => actor.ap_id,
               "to" => [actor.ap_id]
             })

    ctx
  end

  # a Mobilizon person's `Join`, as Mobilizon sends it, addressed to our group and its members collection
  defp mobilizon_joins(ctx, n) do
    assert {:ok, _} =
             Mobilizon.join(n)
             |> Map.merge(%{
               "object" => ctx.group_ap_id,
               "to" => [ctx.group_ap_id, ctx.members_url]
             })
             |> Transformer.handle_incoming()
  end

  defp ap_id_of(pointer) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: pointer)
    actor.ap_id
  end

  # what went out from here: the activities of this type that were made here, by this actor
  defp sent(type, actor_ap_id) do
    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(&(&1.local and &1.data["type"] == type and &1.data["actor"] == actor_ap_id))
  end

  # an `Accept` of this person's `Join`, which the group sent
  defp accepts_of_join(group_ap_id, person_ap_id) do
    for %{data: %{"object" => %{"type" => "Join", "actor" => ^person_ap_id}}} = accept <-
          sent("Accept", group_ap_id),
        do: accept
  end

  defp join_id_of(person_ap_id, group_ap_id),
    do: ActivityPub.Object.fetch_latest_activity(person_ap_id, group_ap_id, "Join").data["id"]

  test "the first remote member's join is accepted as it is today, to them alone", ctx do
    assert [accept] = accepts_of_join(ctx.group_ap_id, Mobilizon.person(1))

    assert accept.data["to"] == [Mobilizon.person(1)]
    refute accept.data["bcc"], "told a member there was none to tell"
  end

  describe "a local person joining" do
    test "sends a Join as them to the members collection, and the remote member in bcc", ctx do
      user = fake_user!()
      assert {:ok, _} = Categories.join_group(user, ctx.group)

      assert [join] = sent("Join", ap_id_of(user))
      assert join.data["object"] == ctx.group_ap_id
      assert ctx.group_ap_id in join.data["to"]
      assert ctx.members_url in join.data["to"]
      assert Mobilizon.person(1) in join.data["bcc"]

      # an open group admits at once, so there is nothing more to say
      assert accepts_of_join(ctx.group_ap_id, ap_id_of(user)) == []
    end

    test "then leaving sends a Leave to the members collection, cc the group", ctx do
      user = fake_user!()
      assert {:ok, _} = Categories.join_group(user, ctx.group)
      assert {:ok, _} = Categories.leave_group(user, ctx.group)

      assert [leave] = sent("Leave", ap_id_of(user))
      assert leave.data["object"] == ctx.group_ap_id
      assert leave.data["to"] == [ctx.members_url]
      assert leave.data["cc"] == [ctx.group_ap_id]
      assert Mobilizon.person(1) in leave.data["bcc"]
    end

    # a group that reviews joins admits them by a moderator, and says so
    test "to a group that reviews joins is followed by the group's Accept", ctx do
      assert :ok =
               Bonfire.Classify.Boundaries.replace(ctx.group, ctx.creator, %{
                 membership: "on_request",
                 visibility: "global",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      user = fake_user!()

      assert {:ok, _} =
               Categories.add_member(ctx.creator, ctx.group, id(user), skip_boundary_check: true)

      assert [_join] = sent("Join", ap_id_of(user))
      assert [accept] = accepts_of_join(ctx.group_ap_id, ap_id_of(user))
      assert ctx.members_url in accept.data["to"]
      assert Mobilizon.person(1) in accept.data["bcc"]
    end

    test "sends nothing from a group that does not federate", ctx do
      assert :ok =
               Bonfire.Classify.Boundaries.replace(ctx.group, ctx.creator, %{
                 membership: "open",
                 visibility: "nonfederated",
                 participation: "anyone",
                 default_content_visibility: "nonfederated"
               })

      user = fake_user!()
      assert {:ok, _} = Categories.join_group(user, ctx.group)

      assert sent("Join", ap_id_of(user)) == []
    end
  end

  describe "remote members" do
    test "a second one admitted gets an Accept that also goes to the members collection", ctx do
      mobilizon_joins(ctx, 2)

      assert [accept] = accepts_of_join(ctx.group_ap_id, Mobilizon.person(2))
      assert Mobilizon.person(2) in accept.data["to"]
      assert ctx.members_url in accept.data["to"]
      assert Mobilizon.person(1) in accept.data["bcc"]
      refute Mobilizon.person(2) in accept.data["bcc"], "told the joiner twice"
    end

    test "removing one sends a Remove naming their Join, and still the Reject of their Follow",
         ctx do
      mobilizon_joins(ctx, 2)

      {:ok, member} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(Mobilizon.person(1))

      assert {:ok, _} = Categories.remove_member(ctx.creator, ctx.group, id(member))

      assert [remove] = sent("Remove", ap_id_of(ctx.creator))
      assert remove.data["object"] == Mobilizon.member_url(1)
      assert remove.data["origin"] == ctx.group_ap_id
      assert Mobilizon.person(1) in remove.data["to"]
      assert ctx.members_url in remove.data["to"]
      assert Mobilizon.person(2) in remove.data["bcc"]

      assert [_ | _] =
               for(
                 %{data: %{"object" => %{"type" => "Follow"}}} = reject <-
                   sent("Reject", ctx.group_ap_id),
                 do: reject
               )
    end

    test "one leaving makes the group send a Remove for the others, naming their Join", ctx do
      mobilizon_joins(ctx, 2)

      assert {:ok, _} =
               Transformer.handle_incoming(
                 Map.merge(Mobilizon.leave(Mobilizon.person(2)), %{
                   "object" => ctx.group_ap_id,
                   "to" => [ctx.members_url],
                   "cc" => [ctx.group_ap_id]
                 })
               )

      assert [remove] = sent("Remove", ctx.group_ap_id)
      assert remove.data["object"] == Mobilizon.member_url(2)
      assert remove.data["origin"] == ctx.group_ap_id
      assert ctx.members_url in remove.data["to"]
      assert Mobilizon.person(1) in remove.data["bcc"]
      refute Mobilizon.person(2) in List.wrap(remove.data["bcc"])
    end

    test "one who joined by a Follow and undoes it (Lemmy) does the same", ctx do
      follow = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Follow",
        "id" => "#{@lemmy}/follow/1",
        "actor" => @lemmy,
        "object" => ctx.group_ap_id,
        "to" => [ctx.group_ap_id]
      }

      assert {:ok, _} = Transformer.handle_incoming(follow)

      assert {:ok, _} =
               Transformer.handle_incoming(%{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "type" => "Undo",
                 "id" => "#{@lemmy}/follow/1/undo",
                 "actor" => @lemmy,
                 "object" => follow,
                 "to" => [ctx.group_ap_id]
               })

      assert [remove] = sent("Remove", ctx.group_ap_id)
      assert remove.data["object"] == follow["id"]
      assert Mobilizon.person(1) in remove.data["bcc"]
    end

    # What Mobilizon's `Transmogrifier.handle_incoming/1` matches on, clause by clause (`transmogrifier.ex`): `Join` and `Accept` need `type`, `object`, `actor` and `id` (`:575-583`, `:240-247`), `Leave` `type`, `object` and `actor` (`:601`), `Remove` `type`, `actor`, `object` and `origin` (`:644-645`). `object` is read by `Utils.get_url/1`, so an id or a map with one; the Remove's is the id of the Join that made the Member, which `get_remove_object/1` and `get_member/1` look up by URL (`:1022-1034`, `:1110-1115`)
    test "what goes out has the keys Mobilizon's handlers read", ctx do
      mobilizon_joins(ctx, 2)
      user = fake_user!()
      assert {:ok, _} = Categories.join_group(user, ctx.group)
      assert {:ok, _} = Categories.leave_group(user, ctx.group)

      {:ok, member} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(Mobilizon.person(1))

      assert {:ok, _} = Categories.remove_member(ctx.creator, ctx.group, id(member))

      outgoing = fn activity ->
        assert {:ok, json} = Transformer.prepare_outgoing(activity.data)
        json
      end

      assert [join] = sent("Join", ap_id_of(user))
      join = outgoing.(join)
      assert %{"type" => "Join", "actor" => actor, "object" => object, "id" => join_id} = join
      assert actor == ap_id_of(user)
      assert object == ctx.group_ap_id, "the Join's object is not the group's id"
      assert is_binary(join_id)

      assert [leave] = sent("Leave", ap_id_of(user))
      assert %{"type" => "Leave", "actor" => ^actor, "object" => ^object} = outgoing.(leave)

      assert [accept] = accepts_of_join(ctx.group_ap_id, Mobilizon.person(2))
      accept = outgoing.(accept)
      assert %{"type" => "Accept", "actor" => group, "object" => accepted, "id" => id} = accept
      assert group == ctx.group_ap_id
      assert is_binary(id)
      assert ActivityPub.Object.get_ap_id(accepted) == Mobilizon.member_url(2)

      assert [remove] = sent("Remove", ap_id_of(ctx.creator))
      remove = outgoing.(remove)

      assert %{"type" => "Remove", "actor" => remover, "object" => removed, "origin" => origin} =
               remove

      assert remover == ap_id_of(ctx.creator)

      assert removed == Mobilizon.member_url(1),
             "not the id of the Join that made the Member: #{inspect(removed)}"

      assert origin == ctx.group_ap_id
    end

    test "making a moderator sends no Update", ctx do
      updates = length(sent("Update", ap_id_of(ctx.creator)))
      user = fake_user!()

      assert {:ok, _} =
               Categories.add_moderator(ctx.creator, ctx.group, id(user),
                 skip_boundary_check: true
               )

      assert length(sent("Update", ap_id_of(ctx.creator))) == updates
    end
  end
end
