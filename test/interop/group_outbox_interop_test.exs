defmodule Bonfire.Federate.ActivityPub.GroupOutboxInteropTest do
  @moduledoc """
  What a group's outbox has to look like for the threadiverse to backfill from it.

  Lemmy reads a community outbox as ONE collection with its items inline, and never follows pages: it takes `orderedItems` from the top-level document, expects each to be an `Announce`, and rejects the lot otherwise — backfilling nothing rather than degrading. That is why our own captures of `lemmy.local` and `piefed.local` each hold exactly 50 items in a single unpaged collection.

  PieFed copes either way, but PREFERS `first` when present, following it for 10 items instead of reading the 50 already inline. So a root-level `first` actively costs us: pagination is exposed through `last` and the `prev` chain instead, which is ordinary AS2 and loses nothing.

  ⚠️ This shape is a response to how implementations behave rather than to anything they promise, so it needs the reasoning kept next to it — otherwise `first` gets added back as a fix.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Classify.Simulate
  alias ActivityPub.Web.ObjectView

  test "a group's outbox is one capped collection with its announces inline" do
    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    assert {:ok, _post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>something to backfill</p>"}},
               boundary: "public",
               publish_in: uid(group)
             )

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

  # The `last` link is what keeps history reachable once a group outgrows one capped collection —
  # asserted here rather than by publishing 51 posts, which would test the same branch far slower.
  test "a group with more history than fits inline links to its last page" do
    url = "https://bonfire.local/pub/actors/agroup/outbox"
    limit = ActivityPub.Web.ObjectView.group_outbox_limit()

    assert %{"last" => last} =
             ActivityPub.Web.Collections.last_page_link(url, limit * 2 + 1, limit)

    assert last == "#{url}?page=3",
           "three pages hold 101 items at #{limit} each, so walking back starts at the third"

    assert ActivityPub.Web.Collections.last_page_link(url, limit, limit) == %{},
           "and exactly one page's worth needs no link at all"
  end
end
