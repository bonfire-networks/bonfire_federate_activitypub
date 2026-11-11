if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupMembersSyncTest do
    @moduledoc """
    The members of a group on another Bonfire instance are copied here when the first of ours is accepted into it, and kept current from what the group tells its members: a person joining, leaving, or being taken out. The group lists its members to a member only (an `on_request` group, `Categories.roster_audience/1`), so the copy is read as the person of ours who was accepted.

    Someone here who only follows the group is no member, so nothing about its members is sent here for them.
    """
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    @moduletag :test_instance

    import Bonfire.Federate.ActivityPub.SharedDataDanceCase
    import Bonfire.Classify.Simulate

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias Bonfire.Classify.Categories

    # a group on the PEER that people join by request, with 12 members (its creator and 11 more)
    setup context do
      creator = context[:remote][:user]

      remote =
        TestInstanceRepo.apply(fn ->
          group = fake_group!(creator, %{type: :group})

          :ok =
            Bonfire.Classify.Boundaries.replace(group, creator, %{
              membership: "on_request",
              visibility: "global",
              participation: "anyone",
              default_content_visibility: "public"
            })

          members =
            for _ <- 1..11 do
              member = fake_user!()

              {:ok, _} =
                Categories.add_member(creator, group, id(member), skip_boundary_check: true)

              member
            end

          %{
            creator: creator,
            group: group,
            members: members,
            group_url: Bonfire.Me.Characters.character_url(group)
          }
        end)

      assert {:ok, %Bonfire.Classify.Category{type: :group} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      {:ok, remote: remote, mirror: mirror, base: Categories.members_count(mirror)}
    end

    test "joined from here and accepted, the group's 12 members are here too, and the changes there follow",
         %{remote: remote, mirror: mirror, base: base} = context do
      joiner = context[:local][:user]
      assert {:ok, %{requested: true}} = Categories.join_group(joiner, mirror)
      accept_there!(remote, joiner)

      # the 12 there and the one of ours
      assert Categories.members_count(mirror) == base + 13

      # a join there (as the peer's moderator admits someone, the group tells its members)
      newcomer = TestInstanceRepo.apply(fn -> add_member_there!(remote) end)
      count = Categories.members_count(mirror)
      assert count == base + 14, "a person who joined there is not known here"
      assert member_here?(newcomer.url, mirror)

      # their leave
      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Categories.leave_group(newcomer.person, remote.group)
      end)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)
      assert Categories.members_count(mirror) == base + 13, "someone who left there is still here"

      # a removal, of someone who joined after we did: the group names the `Join` they made (the id of their Member), which a person admitted before any of ours was a member there never made
      removed = TestInstanceRepo.apply(fn -> add_member_there!(remote) end)
      assert member_here?(removed.url, mirror)

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Categories.remove_member(remote.creator, remote.group, id(removed.person))
      end)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert Categories.members_count(mirror) == base + 13,
             "someone taken out there is still here"

      refute member_here?(removed.url, mirror)
    end

    test "someone here who only follows the group hears nothing of its members", %{
      remote: remote,
      mirror: mirror,
      base: base
    } do
      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(fake_user!(), mirror)
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      newcomer = TestInstanceRepo.apply(fn -> add_member_there!(remote) end)

      assert Categories.members_count(mirror) == base, "a follower was told about members"
      refute member_here?(newcomer.url, mirror)
    end

    # the peer's moderator lets the person of ours in, as the group's page does
    defp accept_there!(remote, joiner) do
      joiner_url = Bonfire.Me.Characters.character_url(joiner)

      TestInstanceRepo.apply(fn ->
        assert {:ok, person} = AdapterUtils.get_by_url_ap_id_or_username(joiner_url)

        assert {:ok, request} =
                 Bonfire.Social.Requests.get(
                   person,
                   Bonfire.Boundaries.Verbs.get_id!(:join),
                   remote.group,
                   current_user: remote.creator
                 )

        assert {:ok, _} = Categories.accept_join_request(remote.creator, request)
      end)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)
    end

    # on the peer: one more person is let in; returns them and their URL
    defp add_member_there!(remote) do
      person = fake_user!()

      assert {:ok, _} =
               Categories.add_member(remote.creator, remote.group, id(person),
                 skip_boundary_check: true
               )

      %{person: person, url: Bonfire.Me.Characters.character_url(person)}
    end

    defp member_here?(person_url, mirror) do
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      case AdapterUtils.get_character_by_ap_id(person_url) do
        {:ok, person} -> Categories.member?(person, mirror)
        _ -> false
      end
    end
  end
end
