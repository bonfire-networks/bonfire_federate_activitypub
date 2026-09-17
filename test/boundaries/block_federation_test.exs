defmodule Bonfire.Federate.ActivityPub.BlockFederationTest do
  @moduledoc """
  Telling a remote server about a block, and what happens when one tells us.

  A `Block` is the loudest disclosure we can make: their server is told outright and may show them. So it rides on the same opt-in as severing the follow (`also_unfollow_and_notify`), rather than going out every time someone blocks.

  Neither direction severs a follow of its own accord. A block is applied as a BOUNDARY, and the boundary is what stops delivery: `federation_allowed?(direction: :out)` drops a ghosted recipient when the publisher expands followers into inboxes. The follow edge is then stale rather than harmful, and leaving it means undoing the block restores the prior state with nothing to record and nothing to rebuild.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @remote "https://blockhost.local/users/blocked"
  @blocker "https://blockhost.local/users/blocker"

  setup_all do
    mock_global(fn
      %{method: :get, url: url} = env ->
        if url in [@remote, @blocker] do
          json(Simulate.actor_json(url, url |> String.split("/") |> List.last()))
        else
          apply(ActivityPub.Test.HttpRequestMock, :request, [env])
        end
    end)
  end

  setup do
    Process.put(:federating, true)
    %{me: fake_user!()}
  end

  defp remote_person(ap_id) do
    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
    {:ok, person} = AdapterUtils.return_pointable(actor)
    person
  end

  # every Block activity this instance has made, however it was queued
  defp blocks_emitted do
    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(&(&1.data["type"] == "Block"))
  end

  defp undos_of_blocks_emitted do
    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(
      &(&1.data["type"] == "Undo" and
          get_in(&1.data, ["object", "type"]) == "Block")
    )
  end

  describe "outgoing" do
    test "asking to notify their server emits a Block", %{me: me} do
      them = remote_person(@remote)

      assert {:ok, _} =
               Blocks.block(them, :ghost, current_user: me, also_unfollow_and_notify: true)

      assert [block] = blocks_emitted()
      assert block.data["actor"] =~ id(me)

      assert ActivityPub.Object.get_ap_id(block.data["object"]) =~ @remote,
             "the Block has to name the person it is about, or their server cannot act on it"
    end

    test "not asking keeps the block to ourselves", %{me: me} do
      them = remote_person(@remote)

      assert {:ok, _} = Blocks.block(them, :ghost, current_user: me)

      assert blocks_emitted() == [],
             "the default is a block they cannot detect, so nothing may go out without being asked for"

      assert Blocks.is_blocked?(them, :ghost, current_user: me),
             "control: the block itself still applies, it is only the telling that is opt-in"
    end

    # A silence is a MUTE: it says "I do not see them", which their server can do nothing about, since my own feed filtering is what does it. Mutes federate nowhere in the fediverse (Mastodon's are local-only), and a `Block` would be read as the far stronger thing.
    test "silencing tells nobody, even when asked to do more", %{me: me} do
      them = remote_person(@remote)

      assert {:ok, _} =
               Blocks.block(them, :silence, current_user: me, also_unfollow_and_notify: true)

      assert blocks_emitted() == [],
             "silencing is a mute, so there is nothing to ask of their server"

      refute Follows.following?(me, them),
             "control: the local half still happens — asking for more severs MY follow of them"
    end

    # Blocking is both halves, so the ghost half emits and the silence half does not, leaving exactly one.
    test "blocking both ways emits a single Block", %{me: me} do
      them = remote_person(@remote)

      assert {:ok, _} =
               Blocks.block(them, :ghost, current_user: me, also_unfollow_and_notify: true)

      assert {:ok, _} =
               Blocks.block(them, :silence, current_user: me, also_unfollow_and_notify: true)

      assert [_one] = blocks_emitted()
    end

    test "blocking someone local tells nobody", %{me: me} do
      neighbour = fake_user!()

      assert {:ok, _} =
               Blocks.block(neighbour, :ghost, current_user: me, also_unfollow_and_notify: true)

      assert blocks_emitted() == [],
             "there is no other server involved, and our own boundaries already enforce it"
    end

    test "unblocking undoes a Block we sent", %{me: me} do
      them = remote_person(@remote)

      assert {:ok, _} =
               Blocks.block(them, :ghost, current_user: me, also_unfollow_and_notify: true)

      assert [_] = blocks_emitted(), "control: there has to be a Block for the Undo to be about"

      assert {:ok, _} = Blocks.unblock(them, :ghost, current_user: me)

      assert [undo] = undos_of_blocks_emitted(),
             "a remote left holding a block we have lifted would keep enforcing it forever"

      assert undo.data["actor"] =~ id(me)
    end

    # The block was opt-in, so its ABSENCE is information too: someone who blocked quietly chose not to tell that server anything, and an `Undo` would reveal the block after the fact.
    test "unblocking tells nobody when the block was never sent", %{me: me} do
      them = remote_person(@remote)

      assert {:ok, _} = Blocks.block(them, :ghost, current_user: me)
      assert {:ok, _} = Blocks.unblock(them, :ghost, current_user: me)

      assert undos_of_blocks_emitted() == [],
             "undoing a block they were never told about would disclose it retroactively"
    end
  end

  describe "incoming" do
    test "a remote blocking one of us applies it here", %{me: me} do
      them = remote_person(@blocker)

      assert {:ok, _} =
               Blocks.ap_receive_activity(
                 them,
                 %{data: %{"type" => "Block"}},
                 %{data: %{"id" => Bonfire.Common.URIs.canonical_url(me)}}
               )

      assert Blocks.is_blocked?(me, :ghost, current_user: them) or
               Blocks.is_blocked?(me, :silence, current_user: them),
             "their wish is respected by a boundary on our side"
    end

    # The behaviour that used to live in `ActivityPub.block/2`, which severed a follow unconditionally. It was removed because the direction depends on the kind of block, which the library cannot know, and because destroying the edge makes `Undo{Block}` unable to put things back.
    test "and does not sever their follow of us", %{me: me} do
      them = remote_person(@blocker)
      {:ok, _} = Follows.follow(them, me, skip_boundary_check: true)

      assert Follows.following?(them, me),
             "control: the follow this test is about must exist before the block"

      assert {:ok, _} =
               Blocks.ap_receive_activity(
                 them,
                 %{data: %{"type" => "Block"}},
                 %{data: %{"id" => Bonfire.Common.URIs.canonical_url(me)}}
               )

      assert Follows.following?(them, me),
             "the boundary stops delivery, so the edge is merely stale — and keeping it is what lets an Undo{Block} restore the prior state"
    end
  end
end
