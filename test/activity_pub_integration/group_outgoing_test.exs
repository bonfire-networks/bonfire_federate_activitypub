defmodule Bonfire.Federate.ActivityPub.GroupOutgoingTest do
  @moduledoc """
  What a post published in one of OUR groups looks like on the wire, and what the group relays.

  FEP-1b12 marks belonging with `audience` naming the group, and Lemmy additionally requires the group in `to`/`cc`: it reads addressing from those alone, so a post that names the group only in `audience` is delivered but not filed. Both are needed, and both have to appear on the OBJECT as well as the activity: Friendica's captures put `audience` only on the `Create`, which is why our own attribution code learned to check both, and Lemmy puts it on the `Page` too.

  A group also announces the COMMENTS in its threads, not only the posts that start them. That is most of what a follower receives: of the 40 most recent statuses mastodon.social held for a Lemmy community, 34 were boosts of comments and 6 of posts. A group that relays only thread starters looks almost silent from the outside, and its threads appear to have no replies. Comments reach followers through the same auto-boost as posts, and a reply's `audience` is derived from its thread rather than named again by the author, which is what lets a reply written anywhere, including from a microblog, be filed as the group's.

  The outbox is the other half of being visible, since it is what a fresh instance backfills from. Lemmy reads a community outbox as ONE collection with its items inline and never follows pages: it takes `orderedItems` from the top-level document, expects each to be an `Announce`, and rejects the lot otherwise, backfilling nothing rather than degrading. That is why our own captures of `lemmy.local` and `piefed.local` each hold exactly 50 items in a single unpaged collection. PieFed copes either way but PREFERS `first` when present, following it for 10 items instead of reading the 50 already inline, so a root-level `first` actively costs us. Pagination is exposed through `last` and the `prev` chain instead, which is ordinary AS2 and loses nothing.

  This is the incoming work from the other side. Everything we ingest depends on remote implementations doing this; a Bonfire group that does not is invisible as a group, however well we read theirs.

  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Outgoing
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias Bonfire.Social.Graph.Follows
  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Web.ObjectView

  @remote_actor "https://mocked.local/users/karen"

  defp public_group(creator) do
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    group
  end

  defp group_ap_id(group) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)
    actor.ap_id
  end

  defp post_in_group(creator, group, html_body) do
    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: html_body}},
               boundary: "public",
               publish_in: uid(group)
             )

    post
  end

  defp reply_to(replier, post, html_body) do
    assert {:ok, reply} =
             Bonfire.Posts.publish(
               current_user: replier,
               post_attrs: %{
                 reply_to_id: uid(post),
                 post_content: %{html_body: html_body}
               },
               boundary: "public"
             )

    reply
  end

  test "a post published in a group names the group in audience, to/cc, and on the object" do
    creator = fake_user!()
    group = public_group(creator)

    post = post_in_group(creator, group, "<p>a post for the group</p>")

    data = Outgoing.ap_activity!(post).data
    group_ap_id = group_ap_id(group)

    # the stored object, which is what we SERVE and what a remote fetch returns, rather than whatever
    # the activity happens to carry inline
    assert {:ok, %{data: object_data}} = ActivityPub.Object.get_cached(pointer: post)

    # a SCALAR, not a list: Lemmy types `audience` as `Option<ObjectId<ApubCommunity>>` on both its
    # `Note` and `Page`, and unlike `to`/`cc` it carries no `deserialize_one_or_many`, so an array
    # fails to parse and the whole activity is rejected with a 400. Every capture we hold sends a
    # bare string. `List.wrap` here would pass for either shape and so assert nothing.
    assert object_data["audience"] == group_ap_id,
           "and on the object too: code that only checks the activity misses Friendica, code that only checks the object misses us. Got #{inspect(object_data["audience"])}"

    assert data["audience"] == group_ap_id,
           "FEP-1b12 marks belonging with `audience`, so a group post without it is just a post"

    assert group_ap_id in (List.wrap(data["to"]) ++ List.wrap(data["cc"])),
           "Lemmy reads addressing from `to`/`cc` alone, so the group has to be there as well"
  end

  # Regression guard for a shape bug only the ACTIVITY showed, while the object stayed correct: `BoundariesMRF.filter_recipients_field/8` filters each addressing field through a list, and used to write the filtered LIST back even when handed a single value, so a scalar `audience` became `["<group>"]` inside `ActivityPub.Object.insert/4`, after every place that builds addressing.
  test "the activity's audience is a scalar, as every implementation sends it" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>a post for the group</p>")

    assert Outgoing.ap_activity!(post).data["audience"] == group_ap_id(group)
  end

  test "the group announces a post published in it" do
    creator = fake_user!()
    group = public_group(creator)

    post = post_in_group(creator, group, "<p>a post for the group</p>")

    assert Bonfire.Social.Boosts.get!(group, post),
           "the group boosts the post locally"

    assert {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

    assert %{data: announce} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), ap_post),
           "a group that never announces its own posts has nothing in its outbox and sends its followers nothing"

    assert announce["type"] == "Announce"
    assert announce["actor"] == group_ap_id(group)
  end

  test "the group announces a reply in its thread" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>a post for the group</p>")

    reply = reply_to(fake_user!(), post, "<p>a comment on it</p>")

    # the local half first, so a failure below points at federation rather than at the auto-boost
    assert Bonfire.Social.Boosts.get!(group, reply),
           "the group boosts the reply locally"

    assert {:ok, ap_reply} = ActivityPub.Object.get_cached(pointer: reply)

    assert %{data: announce} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), ap_reply)

    assert announce["type"] == "Announce"

    assert announce["actor"] == group_ap_id(group),
           "the GROUP announces it, which is what puts it in front of the group's followers"
  end

  test "a reply is marked as belonging to the group, derived from its thread" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>a post for the group</p>")

    reply = reply_to(fake_user!(), post, "<p>a comment on it</p>")

    assert {:ok, %{data: reply_data}} = ActivityPub.Object.get_cached(pointer: reply)

    assert reply_data["audience"] == group_ap_id(group),
           "a comment belongs to the group as much as its thread starter does, and the replier never named the group"
  end

  test "a group's outbox is one capped collection with its announces inline" do
    creator = fake_user!()
    group = public_group(creator)

    post_in_group(creator, group, "<p>something to backfill</p>")

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    outbox = ObjectView.render("outbox.json", %{actor: actor})

    assert outbox["type"] == "OrderedCollection"

    assert is_list(outbox["orderedItems"]) and outbox["orderedItems"] != [],
           "Lemmy reads the items inline and never follows pages, so an empty top level backfills nothing"

    assert is_integer(outbox["totalItems"])

    refute Map.has_key?(outbox, "first"),
           "PieFed prefers `first` when present and would fetch a page of 10 instead of reading what is already here"

    refute Map.has_key?(outbox, "last"),
           "with everything inline there is nothing further back to link to, and a `last` pointing at the page you are holding says nothing"
  end

  # The fan-out rather than the shaping: `prepare_publish_params/2` is where one activity becomes one payload per inbox, so it is where a second shape has to appear. It resolves recipients through the adapter, so it needs a group actor backed by a local pointer and a remote follower to have an inbox at all, which is why this lives here rather than in the AP lib's own tests.
  describe "a group relay goes out as both shapes" do
    setup do
      mock(fn
        %{method: :get, url: @remote_actor} ->
          json(APSimulate.actor_json(@remote_actor))

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}
      end)

      :ok
    end

    defp remote_follower do
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_ap_id(@remote_actor)
      remote_user
    end

    defp announce_of_group_post do
      creator = fake_user!()
      group = public_group(creator)

      {:ok, _} = Follows.follow(remote_follower(), group, skip_boundary_check: true)

      post = post_in_group(creator, group, "<p>a post for the group</p>")

      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)
      {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

      announce = ActivityPub.Object.get_existing_announce(actor.ap_id, ap_post)
      assert %{data: %{"type" => "Announce"}} = announce

      %{creator: creator, group: group, actor: actor, post: post, announce: announce}
    end

    test "publishing a group relay yields both shapes for the same inbox" do
      %{actor: actor, announce: announce} = announce_of_group_post()

      params = APPublisher.prepare_publish_params(actor, announce)

      assert length(params) == 2

      assert params |> Enum.map(& &1.inbox) |> Enum.uniq() |> length() == 1,
             "both shapes go to the same recipient, as two deliveries rather than two audiences"

      assert params |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2,
             "each carries its own id, which is what the receiver stores and may re-fetch"

      shapes = Enum.map(params, &Jason.decode!(&1.json)["object"]["type"])

      assert "Create" in shapes,
             "the 1b12 shape, which Lemmy and the threadiverse require"

      assert Enum.any?(shapes, &(&1 in ["Note", "Page", "Article", "Question"])),
             "and the object shape, which the Pleroma/Misskey/GoToSocial family require"
    end

    test "publishing a person's boost yields one" do
      %{post: post} = announce_of_group_post()

      booster = fake_user!()
      {:ok, _} = Follows.follow(remote_follower(), booster, skip_boundary_check: true)
      assert {:ok, _} = Bonfire.Social.Boosts.boost(booster, post)

      {:ok, booster_actor} = ActivityPub.Actor.get_cached(pointer: booster)
      {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

      boost = ActivityPub.Object.get_existing_announce(booster_actor.ap_id, ap_post)

      assert length(APPublisher.prepare_publish_params(booster_actor, boost)) == 1,
             "one actor repeating an object is not a group relaying an activity"
    end
  end

  # The `last` link is what keeps history reachable once a group outgrows one capped collection,
  # asserted here rather than by publishing 51 posts, which would test the same branch far slower.
  test "a group with more history than fits inline links to its last page" do
    url = "https://bonfire.local/pub/actors/agroup/outbox"
    limit = ObjectView.group_outbox_limit()

    assert %{"last" => last} =
             ActivityPub.Web.Collections.last_page_link(url, limit * 2 + 1, limit)

    assert last == "#{url}?page=3",
           "three pages hold 101 items at #{limit} each, so walking back starts at the third"

    assert ActivityPub.Web.Collections.last_page_link(url, limit, limit) == %{},
           "and exactly one page's worth needs no link at all"
  end
end
