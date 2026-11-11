defmodule Bonfire.Federate.ActivityPub.GroupMobilizonInteropTest do
  @moduledoc """
  Mobilizon groups, which are real community groups rather than a `Group` actor used for something else.

  They have membership proper: `Member` objects carrying roles (invited / not_approved / member / moderator, in a custom `mz:` namespace that predates the FEPs), a `members` collection, a `memberCount`, and separate `discussions`, `events`, `posts`, `resources` and `todos` endpoints. That makes them the closest existing prior art for the member management the non-public plan wants, which is why they are worth their own module rather than a line in a comparison table.

  What they do NOT have is group-actor relay: distribution goes through an instance-level relay actor, and Mobilizon's own docs say federation "fully works only between Mobilizon instances". So there is no announce shape here for us to consume, and these tests are about the ACTOR — what a Mobilizon group becomes when we mirror it.

  ⚠️ The capture (2026-09-02, live public group, hosts rewritten) surfaced a mapping bug: it declares `manuallyApprovesFollowers: false` AND `openness: "moderated"`. Those do not contradict each other, because following and joining are different acts here, and Bonfire models them separately too — `Categories.join_and_follow_group/3` adds someone to the members circle, and has its own branch for people who already follow. We nevertheless read `manuallyApprovesFollowers` as the membership signal, which is only correct where follow IS join, as in the threadiverse.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias Bonfire.Federate.ActivityPub.Testing.MobilizonShapes, as: Mobilizon

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @group "https://mobilizon.local/@framasoft"

  setup do
    served = %{@group => fixture("group_actor.json")}

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    :ok
  end

  test "becomes a local group, carrying its own name" do
    assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => @group})

    assert %Bonfire.Classify.Category{type: :group} = group

    assert e(repo().maybe_preload(group, :profile), :profile, :name, nil) == "Framasoft",
           "a mirrored group should be browsable, which starts with its own name"
  end

  # Fixed 2026-09-02: `remote_dims/1` reads `openness` before falling back to
  # `manuallyApprovesFollowers`. The AS2 field describes FOLLOWING, which only coincides with joining
  # where a group has no membership of its own — true across the threadiverse, false here.
  test "mirrors moderated JOINING, which is not the same as open following" do
    actor = fixture("group_actor.json")

    assert actor["manuallyApprovesFollowers"] == false and actor["openness"] == "moderated",
           "the fixture should carry both, since the whole point is that they differ"

    assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => @group})

    assert Bonfire.Boundaries.Presets.group_dimension_slugs(group)[:membership] == "on_request",
           "the origin moderates who joins, so our mirror must not present joining as open"
  end

  # The roles are the prior art the non-public plan builds on, so pin what the actor advertises:
  # without a `members` collection there is nothing to sync when that work starts.
  test "advertises its membership, which is what member sync would read" do
    actor = fixture("group_actor.json")

    assert actor["members"] =~ "/members"
    assert is_integer(actor["memberCount"])
  end

  # The shapes of what a Mobilizon group sends and serves about its members come from `Testing.MobilizonShapes`, which cites the Mobilizon source of each. Its members collection is served to a signed member only (Mobilizon's `actor_view.ex:16,37-63`), so the mock here serves the pages only when the request is signed by a key in `:mobilizon_members_signers`, and the empty shape a non-member gets otherwise.
  describe "the members of a Mobilizon group" do
    @members for n <- 1..12,
                 do: Mobilizon.member(n, if(n == 1, do: "administrator", else: "member"))

    setup context do
      Process.put(:mobilizon_members_signers, [])
      Process.put(:mobilizon_members_down, false)

      mirror =
        mirror!(Mobilizon.group_actor("open", Map.get(context, :member_count, 12)), @members)

      # the mirror is a member of its own members circle already, so the counts below are over this
      %{mirror: mirror, base: Categories.members_count(mirror)}
    end

    test "are copied when the first of ours is accepted, and not again for the second", %{
      mirror: mirror,
      base: base
    } do
      first = fake_user!()
      allow_members_signed_by(first)

      # a follow alone is not joining, and our own join is not the group's answer to it
      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(first, mirror)
      assert [follow] = sent("Follow", first)
      assert {:ok, _} = Transformer.handle_incoming(answer("Accept", follow))
      drain()
      refute_received {:members_get, _, _}, "read the members on a follow's Accept"

      assert {:ok, _} = Categories.join_group(first, mirror)
      drain()
      refute_received {:members_get, _, _}, "read the members before the group accepted the join"

      accept_join(first)
      drain()

      assert_received {:members_get, url, true}
      assert url =~ Mobilizon.members_url()

      for n <- 1..12 do
        assert {:ok, member} = AdapterUtils.get_character_by_ap_id(Mobilizon.person(n))
        assert Categories.member?(member, mirror), "member #{n} was not copied"
      end

      assert Categories.members_count(mirror) == base + 13

      assert {:ok, administrator} = AdapterUtils.get_character_by_ap_id(Mobilizon.person(1))
      assert Categories.listed_moderator?(administrator, mirror)

      {:ok, moderator} = AdapterUtils.get_character_by_ap_id(Mobilizon.person(2))
      refute Categories.listed_moderator?(moderator, mirror)

      # the control: the copy now holds remote members, so a second local member's accepted join reads nothing
      flush_members_gets()
      second = fake_user!()
      allow_members_signed_by(second)
      assert {:ok, _} = Categories.join_group(second, mirror)
      accept_join(second)
      drain()

      refute_received {:members_get, _, _}, "read the members again for the second member"
      assert Categories.members_count(mirror) == base + 14
    end

    test "are read again at the next accepted join when the first read failed", %{
      mirror: mirror,
      base: base
    } do
      Process.put(:mobilizon_members_down, true)
      first = fake_user!()
      allow_members_signed_by(first)
      assert {:ok, _} = Categories.join_group(first, mirror)
      accept_join(first)
      drain()

      assert_received {:members_get, _, _}, "the sync never tried to read them"
      assert Categories.members_count(mirror) == base + 1, "a failed read changed the members"

      Process.put(:mobilizon_members_down, false)
      second = fake_user!()
      allow_members_signed_by(second)
      assert {:ok, _} = Categories.join_group(second, mirror)
      accept_join(second)
      drain()

      assert Categories.members_count(mirror) == base + 14
    end

    test "are not read when their count is over the limit", %{mirror: mirror, base: base} do
      Process.put([:bonfire_classify, Categories, :remote_members_sync_max], 5)
      user = fake_user!()
      allow_members_signed_by(user)
      assert {:ok, _} = Categories.join_group(user, mirror)
      accept_join(user)
      drain()

      refute_received {:members_get, _, _}, "read the members of a group over the limit"
      assert Categories.members_count(mirror) == base + 1
    end

    # the group states no count, so only the total its collection states tells: that is one read, of the collection and not of its pages
    @tag member_count: nil
    test "are not read past the collection when its total is over the limit", %{
      mirror: mirror,
      base: base
    } do
      Process.put([:bonfire_classify, Categories, :remote_members_sync_max], 5)
      user = fake_user!()
      allow_members_signed_by(user)
      assert {:ok, _} = Categories.join_group(user, mirror)
      accept_join(user)
      drain()

      assert_received {:members_get, url, true}
      assert url == Mobilizon.members_url()
      refute_received {:members_get, _, _}, "read a page of a collection over the limit"
      assert Categories.members_count(mirror) == base + 1
    end
  end

  # What the group tells its members about the others (Mobilizon addresses these to its members collection, which expands to every member's inbox): our mirror keeps its copy of the list current from them, as the group itself or a moderator it lists on its host says so
  describe "changes to the members of a Mobilizon group, as the group says them" do
    @others for n <- 21..27, do: Mobilizon.member(n)
    @intruder "https://other.local/@intruder"

    setup do
      Process.put(:mobilizon_members_signers, [])
      Process.put(:mobilizon_members_down, false)

      mirror =
        mirror!(Mobilizon.group_actor("open"), @members, others: @others, strangers: [@intruder])

      # one of ours is a member there, who signs the fetch of a Member URL, and the administrator of the group is listed as a moderator
      first = fake_user!()
      allow_members_signed_by(first)
      assert {:ok, _} = Categories.join_group(first, mirror)
      accept_join(first)
      drain()
      assert Categories.listed_moderator?(known_person!(1), mirror), "control: the synced list"
      flush_gets()

      %{mirror: mirror}
    end

    test "are applied: an admission, a leave, a removal, a join and a change of role", %{
      mirror: mirror
    } do
      m21 = Enum.at(@others, 0)
      m22 = Enum.at(@others, 1)
      m23 = Enum.at(@others, 2)

      # the group admitting someone else, and again
      refute member?(21, mirror)
      assert {:ok, _} = Transformer.handle_incoming(Mobilizon.accept_join(m21))
      assert member?(21, mirror)
      count = Categories.members_count(mirror)

      assert {:ok, _} =
               m21
               |> Mobilizon.accept_join()
               |> Map.put("id", "https://mobilizon.local/accept/join/again")
               |> Transformer.handle_incoming()

      assert Categories.members_count(mirror) == count, "a repeated admission changed the members"

      # their own leave
      assert {:ok, _} = Transformer.handle_incoming(Mobilizon.leave(Mobilizon.person(21)))
      refute member?(21, mirror)

      # a moderator's removal names the Member URL, which is read as one of ours
      assert {:ok, _} = Transformer.handle_incoming(Mobilizon.accept_join(m22))
      assert member?(22, mirror)

      assert {:ok, _} =
               Mobilizon.person(1)
               |> Mobilizon.remove(Mobilizon.member_url(22), Mobilizon.person(22))
               |> Transformer.handle_incoming()

      url = Mobilizon.member_url(22)
      assert_received {:member_get, ^url, true}
      refute member?(22, mirror)

      # a join of someone on the group's host to an open group
      assert {:ok, _} = Transformer.handle_incoming(Mobilizon.join(23))
      assert member?(23, mirror)
      refute Categories.listed_moderator?(known_person!(23), mirror)

      # and a moderator changing their role, there and back
      assert {:ok, _} =
               m23
               |> Map.put("role", "moderator")
               |> Mobilizon.update_member(Mobilizon.person(1))
               |> Transformer.handle_incoming()

      assert Categories.listed_moderator?(known_person!(23), mirror)

      assert {:ok, _} =
               m23
               |> Mobilizon.update_member(Mobilizon.person(1))
               |> Map.put("id", "https://mobilizon.local/update/back")
               |> Transformer.handle_incoming()

      refute Categories.listed_moderator?(known_person!(23), mirror)
      assert member?(23, mirror), "a member made a plain member again left the group"

      # someone from another host, whose Join is not taken (below), and whom the group then admits, naming the Join we hold
      join =
        Map.merge(Mobilizon.join(27), %{
          "actor" => @intruder,
          "id" => "https://other.local/member/27"
        })

      assert {:cancel, _} = Transformer.handle_incoming(join)

      assert {:ok, _} =
               @intruder
               |> Mobilizon.member_of(join["id"])
               |> Mobilizon.accept_join()
               |> Transformer.handle_incoming()

      assert Categories.member?(known_person!(@intruder), mirror)
    end

    test "are not applied on the word of someone the origin does not vouch for, or about another group",
         %{mirror: mirror} do
      [m24, m25, m26 | _] = Enum.drop(@others, 3)

      # an admission by someone on another host
      assert {:error, _} =
               m24
               |> Mobilizon.accept_join()
               |> Map.put("actor", @intruder)
               |> Transformer.handle_incoming()

      refute member?(24, mirror)

      # an admission to a group that is not this one
      assert {:error, _} =
               %{m25 | "object" => "https://mobilizon.local/@elsewhere"}
               |> Mobilizon.accept_join()
               |> Transformer.handle_incoming()

      refute member?(25, mirror)

      # a leave from someone we do not hold changes nothing and fetches nothing
      known_person!(26)
      flush_gets()
      assert {:ok, _} = Transformer.handle_incoming(Mobilizon.leave(m26["actor"]))
      refute_received {:person_get, _}
      refute_received {:member_get, _, _}
      refute_received {:members_get, _, _}
      refute member?(26, mirror)

      # a join from someone on another host stays refused
      assert {:cancel, _} =
               Mobilizon.join(27)
               |> Map.merge(%{"actor" => @intruder, "id" => "https://other.local/member/27"})
               |> Transformer.handle_incoming()

      refute Categories.member?(known_person!(@intruder), mirror)
    end
  end

  defp known_person!(n) when is_integer(n), do: known_person!(Mobilizon.person(n))

  defp known_person!(ap_id) do
    assert {:ok, person} = AdapterUtils.get_or_fetch_character_by_ap_id(ap_id)
    person
  end

  defp member?(n, mirror) do
    case AdapterUtils.get_character_by_ap_id(Mobilizon.person(n)) do
      {:ok, person} -> Categories.member?(person, mirror)
      _ -> false
    end
  end

  defp flush_gets do
    receive do
      {tag, _} when tag in [:person_get] -> flush_gets()
      {tag, _, _} when tag in [:members_get, :member_get] -> flush_gets()
    after
      0 -> :ok
    end
  end

  # the group's `Accept` of someone's join, with the `Member` as its object as Mobilizon sends it, carrying the id of the `Join` we sent
  defp accept_join(user) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)
    assert [join] = sent("Join", user)

    assert {:ok, _} =
             actor.ap_id
             |> Mobilizon.member_of(join.data["id"])
             |> Mobilizon.accept_join()
             |> Transformer.handle_incoming()
  end

  defp allow_members_signed_by(user) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)

    Process.put(:mobilizon_members_signers, [
      actor.ap_id | Process.get(:mobilizon_members_signers)
    ])
  end

  defp drain, do: Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

  defp flush_members_gets do
    receive do
      {:members_get, _, _} -> flush_members_gets()
    after
      0 -> :ok
    end
  end

  # what went out as this person about the Mobilizon group
  defp sent(type, user) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)

    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(
      &(&1.local and &1.data["type"] == type and &1.data["actor"] == actor.ap_id and
          ActivityPub.Object.get_ap_id(&1.data["object"]) == @group)
    )
  end

  # A Mobilizon group declares no moderators, so none can be listed to vouch for a Reject of a pending join. One from an account on the group's host, attributed to the group, is taken: at worst it clears a request
  describe "a moderator's Reject of our pending join" do
    @rejecter "https://other.local/@rejecter"

    setup do
      Process.put(:mobilizon_members_signers, [])
      Process.put(:mobilizon_members_down, false)

      mirror =
        mirror!(Mobilizon.group_actor("moderated"), [],
          strangers: [Mobilizon.person(2), @rejecter]
        )

      # known here, as the signed delivery of their Reject would make them
      known_person!(Mobilizon.person(2))
      known_person!(@rejecter)

      user = fake_user!()
      assert {:ok, _} = Categories.join_group(user, mirror)
      assert [join] = sent("Join", user)
      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)

      assert Bonfire.Social.Requests.requested?(
               user,
               Bonfire.Boundaries.Verbs.get_id!(:join),
               mirror
             ),
             "control: the join waits"

      %{
        mirror: mirror,
        user: user,
        member: Mobilizon.member_of(actor.ap_id, join.data["id"], "not_approved")
      }
    end

    test "from an account on the group's host clears it", %{
      mirror: mirror,
      user: user,
      member: member
    } do
      Transformer.handle_incoming(Mobilizon.reject_member(member, Mobilizon.person(2)))

      refute Bonfire.Social.Requests.requested?(
               user,
               Bonfire.Boundaries.Verbs.get_id!(:join),
               mirror
             )
    end

    test "from an account on another host changes nothing", %{
      mirror: mirror,
      user: user,
      member: member
    } do
      Transformer.handle_incoming(Mobilizon.reject_member(member, @rejecter))

      assert Bonfire.Social.Requests.requested?(
               user,
               Bonfire.Boundaries.Verbs.get_id!(:join),
               mirror
             )
    end
  end

  # the group's answer to something we sent
  defp answer(type, %{data: %{"id" => id, "actor" => from_us}}) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => type,
      "id" => "#{@group}/#{String.downcase(type)}/#{System.unique_integer([:positive])}",
      "actor" => @group,
      "object" => id,
      "to" => [from_us]
    }
  end

  # The mirror of an open or moderated Mobilizon group, with its members served as a Mobilizon group serves them. Every request is told to the test: the members' as `{:members_get, url, signed_by_a_member?}`
  # `others` are Members the collection does not list (the people the group admits, removes or promotes later), served at their Member URL to a member only, as Mobilizon does; `strangers` are people on another host
  defp mirror!(group_json, members, opts \\ []) do
    test = self()
    member_docs = Mobilizon.members_docs(members)
    non_member_docs = Mobilizon.members_docs_for_non_member()
    others = opts[:others] || []
    member_url_docs = Map.new(members ++ others, &{&1["id"], &1})

    people =
      Map.new(Enum.map(members ++ others, & &1["actor"]) ++ (opts[:strangers] || []), fn id ->
        {id, APSimulate.actor_json(id, id |> Path.basename() |> String.trim_leading("@"))}
      end)

    mock(fn
      %{method: :get, url: @group} ->
        json(group_json)

      %{method: :get, url: url, headers: headers} ->
        cond do
          String.starts_with?(url, Mobilizon.members_url()) ->
            signed? = signed_by_a_member?(headers)
            send(test, {:members_get, url, signed?})
            serve_members(url, signed?, member_docs, non_member_docs)

          member = member_url_docs[url] ->
            signed? = signed_by_a_member?(headers)
            send(test, {:member_get, url, signed?})
            if signed?, do: json(member), else: %Tesla.Env{status: 404, body: ""}

          person = people[url] ->
            send(test, {:person_get, url})
            json(person)

          true ->
            %Tesla.Env{status: 404, body: ""}
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    {:ok, mirror} = Adapter.maybe_create_remote_actor(group_json)
    {:ok, mirror} = Categories.get(id(mirror), skip_boundary_check: true)
    mirror
  end

  defp serve_members(url, signed?, member_docs, non_member_docs) do
    cond do
      Process.get(:mobilizon_members_down) -> %Tesla.Env{status: 500, body: ""}
      signed? && member_docs[url] -> json(member_docs[url])
      non_member_docs[url] -> json(non_member_docs[url])
      true -> %Tesla.Env{status: 404, body: ""}
    end
  end

  defp signed_by_a_member?(headers) do
    signers = Process.get(:mobilizon_members_signers, [])

    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) in ["signature", "signature-input"] and
        Enum.any?(signers, &String.contains?(value, &1))
    end)
  end

  defp fixture(name) do
    @fixtures |> Path.join("mobilizon") |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
