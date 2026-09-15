defmodule Bonfire.Federate.ActivityPub.GhostedFollowerFanoutTest do
  @moduledoc """
  Ghosting a remote FOLLOWER stops your posts reaching them, at the delivery layer rather than by severing the follow.

  This is the case the MRF alone cannot answer. A public post is addressed to `as:Public` and the author's followers collection, so there is no per-recipient list for `BoundariesMRF.filter/2` to prune. The filtering that matters happens later, when `ActivityPub.Federator.APPublisher` expands followers into inboxes: each is checked with `Adapter.federation_allowed?(follower, direction: :out, by_actor: actor)`, which maps `:out` to the `:ghost` block type. Recipients are then grouped per inbox, so dropping the only recipient on an instance drops the delivery to that instance entirely, while an instance with another follower still receives.

  Ghosting means "people I ghosted cannot see me", so the check is on the BLOCKER's ghost list and the direction is theirs: alice ghosts bob, and it is alice's posts that stop reaching bob, not the reverse.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.Blocks

  @ghosted "https://ghosthost.local/users/ghosted"
  @neighbour "https://ghosthost.local/users/neighbour"
  # a third on the same host, so a test can leave TWO standing after a ghost and get the shared-inbox path
  @third "https://ghosthost.local/users/third"
  @elsewhere "https://otherhost.local/users/elsewhere"
  @remote_actors [@ghosted, @neighbour, @third, @elsewhere]

  setup_all do
    mock_global(fn
      %{method: :get, url: url} = env ->
        if url in @remote_actors do
          # `Simulate.actor_json/3` derives every host-scoped field from the id, including a per-HOST `sharedInbox` — which is what makes two of these actors share one delivery
          json(Simulate.actor_json(url, username_from(url)))
        else
          apply(ActivityPub.Test.HttpRequestMock, :request, [env])
        end
    end)
  end

  defp username_from(actor_id), do: actor_id |> String.split("/") |> List.last()

  defp remote_follower_of(author, ap_id) do
    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
    {:ok, user} = Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(actor)
    {:ok, _} = Follows.follow(user, author, skip_boundary_check: true)
    user
  end

  # what the publisher asks before delivering to each remote follower
  defp deliverable?(author_actor, follower) do
    Adapter.federation_allowed?(follower, direction: :out, by_actor: author_actor)
  end

  # publish, run the fan-out, and report the inboxes actually queued for delivery. This is the real answer: the predicate above only says what the publisher SHOULD do
  defp inboxes_delivered_to(author) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "a post for my followers"}},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    Oban.Testing.all_enqueued(repo(), worker: ActivityPub.Federator.Workers.PublisherWorker)
    |> Enum.filter(&(&1.args["op"] == "publish_one"))
    |> Enum.map(&get_in(&1.args, ["params", "inbox"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # the same question with the blocker named explicitly. The publisher does NOT pass `current_user`, so the two disagreeing is the bug this file exists for: `by_actor` has to reach the per-user ghost list too
  defp deliverable_naming_blocker?(author_actor, author, follower) do
    Adapter.federation_allowed?(follower,
      direction: :out,
      by_actor: author_actor,
      current_user: author
    )
  end

  setup do
    Process.put(:federating, true)

    author = fake_user!("ghosting_author")
    {:ok, author_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(author.id)

    %{author: author, author_actor: author_actor}
  end

  test "a follower nobody ghosted is deliverable", %{author: author, author_actor: author_actor} do
    follower = remote_follower_of(author, @elsewhere)

    assert deliverable?(author_actor, follower),
           "the control: without a ghost this follower receives, so a refusal below is the ghost rather than the fixture"
  end

  test "a ghosted follower is not deliverable", %{author: author, author_actor: author_actor} do
    follower = remote_follower_of(author, @ghosted)

    assert {:ok, _} = Blocks.block(follower, :ghost, current_user: author)

    assert Bonfire.Boundaries.Blocks.is_blocked?(follower, :ghost, current_user: author),
           "the ghost itself recorded, so a deliverable answer below would be the delivery check failing to consult it rather than the block failing to happen"

    refute deliverable?(author_actor, follower),
           "ghosting means they cannot see me, and for a remote follower not delivering is the only thing that enforces it"
  end

  # The publisher identifies the blocker with `by_actor` and never passes `current_user`, so these two answering differently is precisely the bug: a per-user ghost would go unconsulted on every follower fan-out, which is how a ghosted person keeps receiving.
  test "naming the blocker explicitly gives the same answer as by_actor alone", %{
    author: author,
    author_actor: author_actor
  } do
    follower = remote_follower_of(author, @ghosted)

    assert {:ok, _} = Blocks.block(follower, :ghost, current_user: author)

    refute deliverable_naming_blocker?(author_actor, author, follower)

    refute deliverable?(author_actor, follower),
           "`by_actor` has to reach the per-user ghost list, since it is the only identification the publisher offers"
  end

  test "a post is delivered to a follower nobody ghosted", %{author: author} do
    remote_follower_of(author, @elsewhere)

    assert (@elsewhere <> "/inbox") in inboxes_delivered_to(author),
           "the control: this is what delivery looks like when nothing is blocked"
  end

  test "no delivery reaches a follower I ghosted", %{author: author} do
    ghosted = remote_follower_of(author, @ghosted)

    assert {:ok, _} = Blocks.block(ghosted, :ghost, current_user: author)

    refute (@ghosted <> "/inbox") in inboxes_delivered_to(author),
           "ghosting means they cannot see me, and not delivering is what enforces it"
  end

  # Two followers on one host, one ghosted. `ap_publisher.ex` addresses the per-actor inbox only when a SINGLE recipient remains on that host, so dropping the ghosted one leaves exactly that, and the neighbour still receives.
  test "ghosting one of two followers on an instance leaves the other addressed directly", %{
    author: author
  } do
    ghosted = remote_follower_of(author, @ghosted)
    remote_follower_of(author, @neighbour)

    assert {:ok, _} = Blocks.block(ghosted, :ghost, current_user: author)

    inboxes = inboxes_delivered_to(author)

    refute (@ghosted <> "/inbox") in inboxes

    assert (@neighbour <> "/inbox") in inboxes,
           "sharing an instance with someone I ghosted is nothing to do with them"
  end

  # ⚠️ THE CASE FILTERING CANNOT REACH, and the reason the `also_unfollow` toggle exists. Ghosting one of three followers on a host leaves two, and `length(ids) > 1` sends ONE post to that host's `sharedInbox` rather than addressing anyone individually — the SAME delivery it would make with nobody ghosted. The ghosted person's server receives it and files it for everyone there who follows me.
  #
  # Asserted as a comparison, because no single assertion here can tell ghosted from not: the delivery is identical either way, and that identity IS the finding.
  test "ghosting changes nothing about a shared-inbox delivery to a host with two other followers",
       %{author: author} do
    ghosted = remote_follower_of(author, @ghosted)
    remote_follower_of(author, @neighbour)
    remote_follower_of(author, @third)

    before_ghosting = inboxes_delivered_to(author)

    assert {:ok, _} = Blocks.block(ghosted, :ghost, current_user: author)

    assert inboxes_delivered_to(author) == before_ghosting,
           "the fan-out cannot exclude someone from a post it must send to their server anyway, which is the gap the unfollow toggle covers"

    assert "https://ghosthost.local/inbox" in before_ghosting,
           "and it really is the shared inbox being used, not per-actor addressing"
  end

  # The same setup WITH the toggle, which is what closes the gap above. The delivery is unchanged — two others on that host still warrant the shared-inbox post, but the ghosted person is no longer among the followers it is built from so their server has no reason to show it to them. That last step happens on their side, so what is checkable here is that they left the set.
  test "also_unfollow removes a ghosted follower from the set the fan-out is built from", %{
    author: author,
    author_actor: author_actor
  } do
    ghosted = remote_follower_of(author, @ghosted)
    remote_follower_of(author, @neighbour)
    remote_follower_of(author, @third)

    assert id(ghosted) in Adapter.get_follower_local_ids(author_actor, :publish),
           "the control: they are a follower until the toggle says otherwise"

    assert {:ok, _} = Blocks.block(ghosted, :ghost, current_user: author, also_unfollow: true)

    refute id(ghosted) in Adapter.get_follower_local_ids(author_actor, :publish),
           "off my followers list, so a shared-inbox post their server receives is not one it holds a subscription for"
  end

  # The LOCAL half of the same guarantee. Nothing is delivered anywhere, so what has to refuse is the boundary rather than the publisher.
  test "a locally ghosted user cannot see my post", %{author: author} do
    ghosted_local = fake_user!("ghosted_local")

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "not for the ghosted"}},
        boundary: "public"
      )

    assert Bonfire.Boundaries.can?(ghosted_local, :read, post),
           "the control: readable before the ghost, so the refusal below is the ghost rather than the boundary preset"

    assert {:ok, _} = Blocks.block(ghosted_local, :ghost, current_user: author)

    refute Bonfire.Boundaries.can?(ghosted_local, :read, post),
           "ghosting means they cannot see me, which locally is the boundary's job rather than the publisher's"
  end

  # The case that shows the drop is per RECIPIENT and not per host: both live on `ghosthost.local` and share its `sharedInbox`, so if ghosting excluded the whole host the neighbour would lose posts they are entitled to.
  #
  # ⚠️ and it is the case delivery filtering cannot fully close. The post still reaches that shared inbox for the neighbour's sake, and the receiving instance files it for everyone there who follows the author, including the ghosted one. Dropping a delivery only hides the post when the ghosted person is the sole recipient on their instance. Severing their follow is what reaches the rest, which is why "also unfollow" is an explicit choice on the block rather than either a default or an omission.
  test "ghosting one follower leaves another on the same instance deliverable", %{
    author: author,
    author_actor: author_actor
  } do
    ghosted = remote_follower_of(author, @ghosted)
    neighbour = remote_follower_of(author, @neighbour)

    assert {:ok, _} = Blocks.block(ghosted, :ghost, current_user: author)

    refute deliverable?(author_actor, ghosted)

    assert deliverable?(author_actor, neighbour),
           "the neighbour shares an instance with someone I ghosted, which is nothing to do with them"
  end

  test "ghosting does not sever the follow by default", %{author: author} do
    follower = remote_follower_of(author, @ghosted)

    assert {:ok, _} = Blocks.block(follower, :ghost, current_user: author)

    assert Follows.following?(follower, author),
           "delivery is what a ghost stops; the follow row is theirs and unfollowing on their behalf would both announce the block and be unrecoverable"
  end

  # The other half of the toggle, and the only thing that reaches a ghosted follower who shares an instance with someone else. It costs what the default avoids: they can tell, and `unblock/3` will not give it back.
  test "ghosting with also_unfollow severs their follow of me", %{author: author} do
    follower = remote_follower_of(author, @ghosted)

    assert {:ok, _} =
             Blocks.block(follower, :ghost, current_user: author, also_unfollow: true)

    refute Follows.following?(follower, author),
           "asking for it is what removes them from my followers, so a shared inbox no longer carries my posts to them"
  end

  # Direction matters: ghosting severs THEIR follow of me, not mine of them, since it is my posts that must stop reaching them. Done with a LOCAL pair because following a REMOTE actor yields a pending `Request` rather than a `Follow` until they Accept, so there would be no outgoing follow here to leave alone.
  test "ghosting with also_unfollow severs only their follow, not mine of them", %{author: author} do
    other = fake_user!("mutually_following")

    {:ok, _} = Follows.follow(other, author, skip_boundary_check: true)
    {:ok, _} = Follows.follow(author, other, skip_boundary_check: true)

    assert {:ok, _} = Blocks.block(other, :ghost, current_user: author, also_unfollow: true)

    refute Follows.following?(other, author),
           "they stop following me, which is what stops my posts reaching them"

    assert Follows.following?(author, other),
           "whether I keep reading them is my business and a separate act, which is what silencing is for"
  end
end
