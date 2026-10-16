defmodule Bonfire.Federate.ActivityPub.RemoteModerationApplyNowUITest do
  @moduledoc """
  A moderator here of a community on another instance: locking, removing from the group or banning sends the activity to the community and waits for it to apply it, unless the moderator ticks the confirmation's box to apply it here at once as well. A local group's confirmations have no such box, since there is nobody to wait for.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures
  alias Bonfire.Boundaries

  @community "https://lemmy.local/c/technology"

  @technology %{
    name: "Lemmy",
    dir: "lemmy",
    id: @community,
    actor: "community_actor.json",
    announces: ["announce_create_page_text.json"]
  }

  # the checkbox, not the hidden `"false"` sent when it's unticked, which has the same name
  @apply_now "input[data-role=apply_now]"

  setup do
    account = fake_account!()
    me = fake_user!(account)
    {:ok, %{ap_id: my_ap_id}} = ActivityPub.Actor.get_cached(pointer: me)

    served = Map.new(served_for([@technology]))
    moderators = fixture("lemmy", "community_actor.json")["attributedTo"]

    # the community lists me among its moderators
    served =
      Map.put(served, moderators, %{
        "type" => "OrderedCollection",
        "id" => moderators,
        "orderedItems" => [my_ap_id]
      })

    mock_global(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    announce = fixture("lemmy", "announce_create_page_text.json")
    receive_announce(announce)
    post = announced_post!("Lemmy text post", announce["object"]["object"]["id"])

    {:ok, group} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @community})

    assert {:ok, _} = Bonfire.Classify.Categories.sync_remote_moderators(group, moderators)

    assert Boundaries.can?(me, :mediate, group),
           "control: listed by the community, so a moderator of our mirror"

    someone = fake_user!()
    assert Boundaries.can?(someone, :reply, post), "control: open for replies"

    assert Bonfire.Social.Boosts.boosted?(group, post), "control: in the group"

    {:ok,
     me: me,
     my_ap_id: my_ap_id,
     someone: someone,
     post: post,
     group: group,
     conn: conn(user: me, account: account)}
  end

  defp sent(type, actor) do
    Bonfire.Common.Repo.all(ActivityPub.Object)
    |> Enum.filter(&(&1.local and &1.data["type"] == type and &1.data["actor"] == actor))
  end

  defp open_post_menu(conn, post) do
    conn
    |> visit("/post/#{id(post)}")
    |> wait_async()
    |> assert_has("[data-object_id='#{id(post)}']")
    |> open_more_menu()
  end

  defp open_lock(conn, post) do
    conn
    |> open_post_menu(post)
    |> click_button("[data-role=lock_discussion] [data-role=open_modal]", "Lock discussion")
  end

  defp open_removal(conn, post) do
    conn
    |> open_post_menu(post)
    |> click_button("[data-role=remove_from_group] [data-role=open_modal]", "Remove from group")
  end

  defp tick(session), do: check(session, @apply_now, "Apply it here now", exact: false)

  # whether a moderator may take a post out of its group can be read off the POST's own boundary (its moderators get `:mediate` on what is published in the group, through the group's moderators ACL) rather than the group's, so a feed that has loaded each post's boundary answers it without a query per card. For that, both must agree, for a mirrored community's posts as for a local group's
  describe "moderating a post, asked of the post or of its group" do
    test "agree for a post received from a mirrored community", %{me: me, post: post, group: group} do
      assert Boundaries.can?(me, :mediate, group), "control: a moderator of the mirror"

      assert Boundaries.can?(me, :mediate, post) == Boundaries.can?(me, :mediate, group)

      someone = fake_user!()
      refute Boundaries.can?(someone, :mediate, post), "control: not anyone's"
    end

    test "agree for a post in a local group", %{me: me} do
      group = Bonfire.Classify.Simulate.fake_group!(me)
      author = fake_user!()
      assert {:ok, _} = Bonfire.Classify.Categories.add_member(me, group, id(author))
      post = Bonfire.Classify.Simulate.fake_post_in_group!(author, group, "<p>theirs</p>")

      assert Boundaries.can?(me, :mediate, group), "control: its creator moderates it"

      assert Boundaries.can?(me, :mediate, post) == Boundaries.can?(me, :mediate, group)
    end
  end

  describe "locking" do
    test "ticked, closes the thread here at once, and sends the Lock", %{
      conn: conn,
      post: post,
      someone: someone,
      my_ap_id: my_ap_id
    } do
      conn
      |> open_lock(post)
      |> tick()
      |> click_button("[data-role=lock_confirm]", "Lock this discussion")

      refute Boundaries.can?(someone, :reply, post), "closed at once"
      assert [_] = sent("Lock", my_ap_id)
    end

    test "unticked, sends the Lock and leaves the thread open until the community applies it",
         %{conn: conn, post: post, someone: someone, my_ap_id: my_ap_id} do
      conn
      |> open_lock(post)
      |> assert_has(@apply_now)
      |> click_button("[data-role=lock_confirm]", "Lock this discussion")

      assert [_] = sent("Lock", my_ap_id)
      assert Boundaries.can?(someone, :reply, post), "nothing applied here yet"
    end

    test "in a local group, offers no box", %{conn: conn, me: me} do
      group = Bonfire.Classify.Simulate.fake_group!(me)
      # a member, so their post is published INTO the group and carries its moderators' ACL (joining a group with the default membership may only file a request)
      author = fake_user!()
      assert {:ok, _} = Bonfire.Classify.Categories.add_member(me, group, id(author))
      post = Bonfire.Classify.Simulate.fake_post_in_group!(author, group, "<p>theirs</p>")

      assert Bonfire.Boundaries.can?(me, :mediate, post),
             "control: the group's creator moderates what is published in it"

      conn
      |> open_lock(post)
      |> assert_has("[data-role=lock_confirm]")
      |> refute_has(@apply_now)
    end
  end

  describe "removing from the group" do
    test "ticked, takes the post out here at once", %{conn: conn, post: post, group: group} do
      conn
      |> open_removal(post)
      |> tick()
      |> click_button("[data-role=remove_from_group_confirm]", "Remove from group")

      refute Bonfire.Social.Boosts.boosted?(group, post), "out at once"
    end

    test "unticked, leaves it in until the community applies it", %{
      conn: conn,
      post: post,
      group: group
    } do
      conn
      |> open_removal(post)
      |> assert_has(@apply_now)
      |> click_button("[data-role=remove_from_group_confirm]", "Remove from group")

      assert Bonfire.Social.Boosts.boosted?(group, post), "nothing applied here yet"
    end
  end

  # from a reported post on the group's moderation page, which shows its author's ghost, silence and block buttons given the group as scope
  describe "banning from the group" do
    setup %{post: post} do
      Process.put([:bonfire, :default_pagination_limit], 10)

      author =
        post
        |> repo().maybe_preload(created: [creator: [:profile, character: [:peered]]])
        |> e(:created, :creator, nil)

      {:ok, _} = Bonfire.Social.Flags.flag(fake_user!(), post, comment: "spam")

      {:ok, author: author}
    end

    defp open_ban(conn, group, author) do
      conn
      |> visit("/group/#{group.character.username}/settings/moderation")
      |> wait_async()
      |> click_button("[data-role=open_modal]", "Silence #{author.profile.name}")
      |> assert_has("[data-role=group_block]")
    end

    defp silenced_in_group?(author, group) do
      Bonfire.Boundaries.Blocks.is_blocked?(author, :silence, current_user: group)
    end

    test "ticked, keeps them out here at once", %{conn: conn, group: group, author: author} do
      conn
      |> open_ban(group, author)
      |> within("[data-role=group_block]", &tick/1)
      |> click_button("[data-role=block_from_group]", "Silence in the group")

      assert silenced_in_group?(author, group), "silenced at once"
    end

    test "unticked, waits for the community", %{
      conn: conn,
      group: group,
      author: author,
      my_ap_id: my_ap_id
    } do
      conn
      |> open_ban(group, author)
      |> within("[data-role=group_block]", &assert_has(&1, @apply_now))
      |> click_button("[data-role=block_from_group]", "Silence in the group")

      assert [_] = sent("Block", my_ap_id)
      refute silenced_in_group?(author, group), "nothing applied here yet"
    end
  end
end
