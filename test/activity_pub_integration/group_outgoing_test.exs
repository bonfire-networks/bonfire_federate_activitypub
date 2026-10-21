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
             Bonfire.Classify.Boundaries.replace(group, creator, %{
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

  # Mbin files a `Note` as a microblog post whatever its `name`, and only a `Page` (or `Article`, `Video`) as a thread, so a titled post that starts a thread in a group has to go out as a `Page`. It is decided once, when the object is built: every recipient, the group's relay in both shapes and the object endpoint all carry the same type. A titled post on someone's own timeline, a reply and an untitled post are still a `Note`.
  describe "a titled post that starts a thread in a group is a Page" do
    setup do
      mock(fn
        %{method: :get, url: @remote_actor} ->
          json(APSimulate.actor_json(@remote_actor))

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}
      end)

      creator = fake_user!()
      group = public_group(creator)
      {:ok, _} = Follows.follow(remote_follower(), group, skip_boundary_check: true)

      %{creator: creator, group: group}
    end

    defp titled_post(author, opts) do
      post_attrs =
        %{post_content: %{name: opts[:title], html_body: opts[:body] || "<p>the body</p>"}}
        |> then(&if opts[:reply_to], do: Map.put(&1, :reply_to_id, uid(opts[:reply_to])), else: &1)

      assert {:ok, post} =
               Bonfire.Posts.publish(
                 [current_user: author, post_attrs: post_attrs, boundary: "public"] ++
                   if(opts[:group], do: [publish_in: uid(opts[:group])], else: [])
               )

      post
    end

    defp served_type(post) do
      assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)
      data["type"]
    end

    # both shapes of the group's relay, as delivered to a follower on another instance
    defp relay_payloads(group, post) do
      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)
      {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)
      announce = ActivityPub.Object.get_existing_announce(actor.ap_id, ap_post)
      assert %{data: %{"type" => "Announce"}} = announce

      APPublisher.prepare_publish_params(actor, announce) |> Enum.map(&Jason.decode!(&1.json))
    end

    test "in the 1b12 relay shape, where the Create is embedded", %{creator: creator, group: group} do
      post = titled_post(creator, title: "A thread title", group: group)

      payload =
        relay_payloads(group, post)
        |> Enum.find(&(e(&1, "object", "type", nil) == "Create")) ||
          flunk("no relay in the 1b12 shape")

      assert payload["object"]["object"]["type"] == "Page"
      assert payload["object"]["object"]["name"] == "A thread title"
    end

    test "in the bare-object relay shape, which microblog software re-fetches by id", %{
      creator: creator,
      group: group
    } do
      post = titled_post(creator, title: "A thread title", group: group)

      payload =
        relay_payloads(group, post)
        |> Enum.find(&(e(&1, "object", "type", nil) != "Create")) ||
          flunk("no relay in the object shape")

      assert payload["object"]["type"] == "Page"
    end

    test "and as the object endpoint serves it", %{creator: creator, group: group} do
      post = titled_post(creator, title: "A thread title", group: group)

      assert served_type(post) == "Page"
    end

    test "a titled post on the author's own timeline is a Note", %{creator: creator} do
      post = titled_post(creator, title: "A title, no group")

      assert served_type(post) == "Note"
    end

    test "a reply in a group is a Note, titled or not", %{creator: creator, group: group} do
      thread = titled_post(creator, title: "A thread title", group: group)

      assert served_type(titled_post(creator, title: "A reply title", reply_to: thread)) == "Note"
      assert served_type(titled_post(creator, title: nil, reply_to: thread)) == "Note"
    end

    test "an untitled post that starts a thread in a group is a Note", %{
      creator: creator,
      group: group
    } do
      post = titled_post(creator, title: nil, group: group)

      assert served_type(post) == "Note"
    end
  end

  # The same rule for a group hosted elsewhere, read where it matters: in what is delivered to that group's own inbox.
  describe "a titled post that starts a thread in a group hosted elsewhere is a Page" do
    import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures, only: [fixture: 2, served_for: 1]

    @lemmy %{
      name: "Lemmy",
      dir: "lemmy",
      id: "https://lemmy.local/c/technology",
      actor: "community_actor.json",
      announces: []
    }

    setup do
      served = Map.new(served_for([@lemmy]))

      mock(fn
        %{method: :get, url: url} ->
          case served[url] do
            nil -> %Tesla.Env{status: 404, body: ""}
            body -> json(body)
          end

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}
      end)

      assert {:ok, group} =
               Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{
                 "id" => @lemmy.id
               })

      user = fake_user!()
      assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(user, group)

      %{user: user, group: group}
    end

    defp delivered_to_group_inbox(user, post) do
      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)
      group = fixture("lemmy", "community_actor.json")
      group_inboxes = [group["inbox"], e(group, "endpoints", "sharedInbox", nil)]

      APPublisher.prepare_publish_params(actor, Outgoing.ap_activity!(post))
      |> Enum.filter(&(&1.inbox in group_inboxes))
      |> Enum.map(&Jason.decode!(&1.json))
    end

    test "the Create delivered to the group's inbox carries a Page", %{user: user, group: group} do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: user,
                 post_attrs: %{post_content: %{name: "A thread title", html_body: "<p>body</p>"}},
                 boundary: "public",
                 publish_in: uid(group)
               )

      assert [payload | _] = delivered_to_group_inbox(user, post),
             "control: something is delivered to the group's inbox"

      assert payload["object"]["type"] == "Page"
      assert payload["object"]["audience"] == @lemmy.id
    end

    test "an untitled post to the same group stays a Note", %{user: user, group: group} do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: user,
                 post_attrs: %{post_content: %{html_body: "<p>body</p>"}},
                 boundary: "public",
                 publish_in: uid(group)
               )

      assert [payload | _] = delivered_to_group_inbox(user, post)
      assert payload["object"]["type"] == "Note"
    end
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

  # the options the Mastodon API publishes a group post with when no visibility is given (`Bonfire.Posts.API.MastoAdapter`): the audience in `to_boundaries`, the group in `context_id`, and no `boundary` or `publish_in`
  test "the group announces a post whose audience was given as `to_boundaries`" do
    creator = fake_user!()
    group = public_group(creator)

    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>a post for the group</p>"}},
               to_boundaries: ["public"],
               context_id: uid(group)
             )

    assert {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

    assert ActivityPub.Utils.public?(ap_post.data),
           "the post is public, so its object has to be addressed to Public. Got to: #{inspect(ap_post.data["to"])}, cc: #{inspect(ap_post.data["cc"])}"

    assert %{data: %{"type" => "Announce"}} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), ap_post),
           "a group only announces a public post"
  end

  # the group's followers got the post through the group, so they only see the edit if the group relays it too, as Lemmy's `send_activity_in_community` does for an author's `Update`
  test "the group relays an edit of a post published in it" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>before the edit</p>")
    assert {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

    assert {:ok, _} =
             Bonfire.Social.PostContents.edit(creator, id(post), %{
               html_body: "<p>after the edit</p>"
             })

    assert %{} = update = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Update"),
           "control: the edit federated an Update"

    assert %{data: %{"type" => "Announce"}} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), update),
           "the group's followers keep the old version unless the group relays the edit"
  end

  test "the group relays its author deleting a post published in it" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>soon gone</p>")
    assert {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

    assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: creator)

    assert %{} = delete = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
           "control: the deletion federated a Delete"

    assert %{data: %{"type" => "Announce"}} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), delete),
           "the group's followers keep a deleted post unless the group relays its deletion"
  end

  # The relayed `Announce{Delete}` is understood by Lemmy and the threadiverse, but Mastodon (and GoToSocial, Akkoma, Misskey) ignore it, so a follower there keeps the group's boost of a post that no longer exists. Found against `@mayel@mastodon.social` on 20 October (`group_account_live_test.exs`). Taking the boost back is what removes it for them, and it needs nobody's key but the group's.
  test "the group takes its boost back when its author deletes a post published in it" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>soon gone, and not boosted any more</p>")

    assert {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

    assert %{data: announce} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), ap_post),
           "control: the group announced it, so there is an Announce to undo"

    assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: creator)

    assert ActivityPub.Object
           |> repo().all()
           |> Enum.any?(
             &(&1.data["type"] == "Undo" and &1.data["actor"] == group_ap_id(group) and
                 ActivityPub.Object.get_ap_id(&1.data["object"]) == announce["id"])
           ),
           "the post was deleted but the group never took its boost back, so servers that ignore a relayed `Announce{Delete}` keep showing it"
  end

  # a moderator may delete a member's post (the moderate role includes `:delete`), and that delete takes the same path as an author's
  test "the group relays a moderator deleting a member's post" do
    moderator = fake_user!()
    group = public_group(moderator)
    member = fake_user!()
    assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(member, group)

    post = post_in_group(member, group, "<p>a member's post</p>")
    assert {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

    assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: moderator),
           "control: a moderator may delete a member's post"

    assert %{} = delete = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete")

    assert %{data: %{"type" => "Announce"}} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), delete)
  end

  # A ban (`Blocks.block/3` with `on_behalf_of: group`) is applied here, and federates only when the moderator ticks the box (`also_unfollow_and_notify`, as for a personal block). Then it goes out as Lemmy's ban (`block_user.json`): the MODERATOR's `Block` of the person, `to` Public, `cc` and `target` and `audience` the group, the reason in `summary`, relayed by the group to its followers. Unlike a personal block, a silence federates too (it is Lemmy's ban), and so does a ban of someone local (the group's followers elsewhere need it)
  describe "banning someone from a group we host" do
    setup do
      moderator = fake_user!()
      group = public_group(moderator)
      person = fake_user!()
      {:ok, %{ap_id: moderator_ap_id}} = ActivityPub.Actor.get_cached(pointer: moderator)
      {:ok, %{ap_id: person_ap_id}} = ActivityPub.Actor.get_cached(pointer: person)

      sent_by_moderator = fn type ->
        Bonfire.Common.Repo.all(ActivityPub.Object)
        |> Enum.filter(&(&1.data["type"] == type and &1.data["actor"] == moderator_ap_id))
      end

      {:ok,
       moderator: moderator,
       group: group,
       person: person,
       person_ap_id: person_ap_id,
       sent: sent_by_moderator}
    end

    # a block is both halves, and still ONE `Block` (a silence alone sends one; a ghost alone sends none, below)
    for type <- [:silence, :block] do
      test "a #{type} with the box ticked sends the moderator's Block naming the group, which the group relays",
           %{
             moderator: moderator,
             group: group,
             person: person,
             person_ap_id: person_ap_id,
             sent: sent
           } do
        assert {:ok, _} =
                 Bonfire.Boundaries.Blocks.block(person, unquote(type),
                   current_user: moderator,
                   on_behalf_of: group,
                   also_unfollow_and_notify: true,
                   reason: "spam post"
                 )

        assert [%{data: block} = activity] = sent.("Block")
        assert block["object"] == person_ap_id, "of the person, local here"
        assert block["target"] == group_ap_id(group)
        assert block["audience"] == group_ap_id(group)
        assert block["summary"] == "spam post"
        assert "https://www.w3.org/ns/activitystreams#Public" in List.wrap(block["to"])
        assert group_ap_id(group) in List.wrap(block["cc"])

        assert %{data: %{"type" => "Announce"}} =
                 ActivityPub.Object.get_existing_announce(group_ap_id(group), activity),
               "the group relays it to its followers"
      end
    end

    # A peer can only act on a `Block` as a ban from taking part (Lemmy, PieFed and Mbin read it so, with no type, and the microblog software not at all): a ghost keeps someone from SEEING the group, which a peer holding a public copy can't enforce, and would apply as a silence, the half the moderator didn't choose. So a ghost stays on this instance
    test "a ghost with the box ticked sends no Block, and still ghosts them from the group", %{
      moderator: moderator,
      group: group,
      person: person,
      sent: sent
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :ghost,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true,
                 reason: "spam post"
               )

      assert Bonfire.Boundaries.Blocks.is_blocked?(person, :ghost, current_user: group),
             "the ghost itself happened, so nothing sent below is the ghost failing rather than staying home"

      assert sent.("Block") == []

      # the control, so the empty list means a ghost and not a ban that can't federate at all: a silence of someone else, with the box, does go out
      other = fake_user!()

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(other, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [_] = sent.("Block"), "control: a silence with the box goes out"
    end

    test "unghosting a ghost-only ban sends no Undo", %{
      moderator: moderator,
      group: group,
      person: person,
      sent: sent
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :ghost,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.unblock(person, :ghost,
                 current_user: moderator,
                 on_behalf_of: group
               )

      refute Bonfire.Boundaries.Blocks.is_blocked?(person, :ghost, current_user: group),
             "control: the ghost is lifted"

      assert sent.("Undo") == []
    end

    test "with no reason given, it says a moderator banned them", %{
      moderator: moderator,
      group: group,
      person: person,
      sent: sent
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [%{data: %{"summary" => "Banned by a moderator"}}] = sent.("Block")
    end

    test "without the box, nothing leaves the instance", %{
      moderator: moderator,
      group: group,
      person: person,
      sent: sent
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group
               )

      assert sent.("Block") == []

      # the control, so the silence above means the box and not a ban that can't federate at all: the same ban of someone else, with the box, does go out
      other = fake_user!()

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(other, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [_] = sent.("Block"), "control: with the box, it goes out"
    end

    test "unbanning sends the moderator's Undo of it, addressed as the ban was", %{
      moderator: moderator,
      group: group,
      person: person,
      sent: sent
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [%{data: %{"id" => block_id}}] = sent.("Block")

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.unblock(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group
               )

      assert [%{data: undo}] =
               Enum.filter(sent.("Undo"), &(e(&1.data, "object", "id", nil) == block_id))

      assert group_ap_id(group) in List.wrap(undo["cc"])
    end

    # what the group's own boundaries say about federating still decides it: a group that doesn't federate sends no ban either
    test "a group that doesn't federate sends nothing", %{
      moderator: moderator,
      group: group,
      person: person,
      sent: sent
    } do
      local_group =
        Simulate.fake_group!(moderator, %{
          membership: "open",
          visibility: "nonfederated",
          participation: "anyone"
        })

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: local_group,
                 also_unfollow_and_notify: true
               )

      assert sent.("Block") == []

      # the control, so the silence above means the group's boundaries and not a ban that can't federate at all: the same ban, from a group that federates, does go out
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [_] = sent.("Block"), "control: from a federating group, it goes out"
    end
  end

  # A like reaches the post's author and the group, and nobody else: followers' instances only count a vote the group relays, as Lemmy, PieFed, Mbin and NodeBB all do. Without it a post's count on their copy of the group is only their own users' votes
  describe "the group relays votes on a post published in it" do
    setup do
      mock(fn
        %{method: :get, url: @remote_actor} -> json(APSimulate.actor_json(@remote_actor))
        _ -> %Tesla.Env{status: 404, body: ""}
      end)

      creator = fake_user!()
      group = public_group(creator)
      post = post_in_group(creator, group, "<p>a post to vote on</p>")
      assert {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

      {:ok, group: group, post: post, ap_post: ap_post}
    end

    test "a member's like", %{group: group, post: post, ap_post: ap_post} do
      liker = fake_user!()
      assert {:ok, _} = Bonfire.Social.Likes.like(liker, post)
      {:ok, %{ap_id: liker_ap_id}} = ActivityPub.Actor.get_cached(pointer: liker)

      assert %{} = like = ActivityPub.Object.get_existing_like(liker_ap_id, ap_post.data["id"]),
             "control: the like federated"

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id(group), like)
    end

    test "and its undoing", %{group: group, post: post, ap_post: ap_post} do
      liker = fake_user!()
      assert {:ok, _} = Bonfire.Social.Likes.like(liker, post)
      {:ok, %{ap_id: liker_ap_id}} = ActivityPub.Actor.get_cached(pointer: liker)

      %{data: %{"id" => like_id}} =
        ActivityPub.Object.get_existing_like(liker_ap_id, ap_post.data["id"])

      assert {:ok, _} = Bonfire.Social.Likes.unlike(liker, post)

      assert %{} = undo = ActivityPub.Object.get_activity_for_object_ap_id(like_id, "Undo"),
             "control: the unlike federated an Undo"

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id(group), undo)
    end

    # most votes on a busy group's posts come from other instances, delivered to the group's inbox
    test "a remote voter's like", %{group: group, post: post, ap_post: ap_post} do
      like = %{
        "type" => "Like",
        "id" => "#{@remote_actor}/likes/group-post",
        "actor" => @remote_actor,
        "object" => ap_post.data["id"],
        "to" => [ap_post.data["attributedTo"]],
        "cc" => [group_ap_id(group)]
      }

      # the transformer hands a remote activity to the adapter itself, as a real delivery does, so applying it again here would relay it twice
      assert {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(like)

      {:ok, remote_user} = Bonfire.Me.Users.by_ap_id(@remote_actor)

      assert Bonfire.Social.Likes.liked?(remote_user, post),
             "control: the remote like was applied here"

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id(group), activity)
    end
  end

  # A moderator of one of our groups who is on another instance locks a post in it: their `Lock` comes to the group's inbox, is applied here, and the group passes it on, unchanged, to its followers, as Lemmy's communities do (`RawAnnouncableActivities::receive` → `AnnounceActivity::send(self, …)`). That relay is also how the moderator's own instance learns the group applied it
  describe "the group relays what a moderator on another instance did in it" do
    setup do
      mock(fn
        %{method: :get, url: @remote_actor} -> json(APSimulate.actor_json(@remote_actor))
        %{method: :post} -> %Tesla.Env{status: 202, body: ""}
        _ -> %Tesla.Env{status: 404, body: ""}
      end)

      creator = fake_user!()
      group = public_group(creator)
      author = fake_user!()
      {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(author, group)
      post = post_in_group(author, group, "<p>a member's post a remote moderator acts on</p>")
      assert {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, remote_moderator} = Bonfire.Me.Users.by_ap_id(@remote_actor)

      # someone on another instance is promoted only once they are a member, which their own Follow makes them
      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(%{
                 "type" => "Follow",
                 "id" => "#{@remote_actor}/follows/group",
                 "actor" => @remote_actor,
                 "object" => group_ap_id(group)
               })

      assert {:ok, _} =
               Bonfire.Classify.Categories.add_moderator(creator, group, remote_moderator)

      {:ok, group: group, post: post, ap_post: ap_post}
    end

    test "a Lock", %{group: group, post: post, ap_post: ap_post} do
      someone = fake_user!()
      assert Bonfire.Boundaries.can?(someone, :reply, post), "control: the thread starts out open"

      lock = %{
        "type" => "Lock",
        "id" => "#{@remote_actor}/locks/group-post",
        "actor" => @remote_actor,
        "object" => ap_post.data["id"],
        "summary" => "off topic",
        "audience" => group_ap_id(group),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [group_ap_id(group)]
      }

      assert {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(lock)

      refute Bonfire.Boundaries.can?(someone, :reply, post),
             "control: the remote moderator's Lock was applied here"

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id(group), activity),
             "the group relays it"
    end

    # Lemmy's ban (`block_user.json`): the moderator's `Block` of the person with `target` the group
    test "a ban", %{group: group, post: post} do
      banned = fake_user!()
      {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(banned, group)
      {:ok, %{ap_id: banned_ap_id}} = ActivityPub.Actor.get_cached(pointer: banned)
      assert Bonfire.Boundaries.can?(banned, :reply, post), "control: they may reply before"

      ban = %{
        "type" => "Block",
        "id" => "#{@remote_actor}/blocks/group-member",
        "actor" => @remote_actor,
        "object" => banned_ap_id,
        "target" => group_ap_id(group),
        "summary" => "spam",
        "audience" => group_ap_id(group),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [group_ap_id(group)]
      }

      assert {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(ban)

      refute Bonfire.Boundaries.can?(banned, :reply, post),
             "control: the remote moderator's ban was applied here"

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id(group), activity),
             "the group relays it"
    end

    # the threadiverse's mod "remove" (`mod_remove_note.json`): the moderator's `Delete` of the post, a removal by its `summary`
    test "a removal", %{group: group, post: post, ap_post: ap_post} do
      reader = fake_user!()

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: reader
             ),
             "control: the post is in the group to begin with"

      remove = %{
        "type" => "Delete",
        "id" => "#{@remote_actor}/deletes/group-post",
        "actor" => @remote_actor,
        "object" => ap_post.data["id"],
        "summary" => "spam",
        "audience" => group_ap_id(group),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [group_ap_id(group)]
      }

      assert {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(remove)

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: reader
             ),
             "control: the remote moderator's removal was applied here"

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id(group), activity),
             "the group relays it"
    end
  end

  # Reopening a thread is sent as the `Lock`'s own `Undo`, addressed as the `Lock` was and naming the group it is in, which a receiver checks a moderator's standing against. The group then passes it on to its followers, as it does the `Lock`
  test "unlocking a post in the group sends an Undo of the Lock, naming the group, which the group announces" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>a thread the moderator closes and reopens</p>")
    {:ok, %{ap_id: creator_ap_id}} = ActivityPub.Actor.get_cached(pointer: creator)

    sent_by_creator = fn type ->
      ActivityPub.Object
      |> repo().all()
      |> Enum.filter(&(&1.data["type"] == type and &1.data["actor"] == creator_ap_id))
    end

    assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: creator)
    assert [lock] = sent_by_creator.("Lock"), "control: the Lock went out"
    assert lock.data["audience"] == group_ap_id(group), "control: and names the group"

    assert {:ok, _} = Bonfire.Boundaries.Blocks.unlock(post, current_user: creator)

    assert [undo] = sent_by_creator.("Undo")
    assert undo.data["object"]["type"] == "Lock"
    assert undo.data["to"] == lock.data["to"]
    assert undo.data["cc"] == lock.data["cc"]

    assert undo.data["audience"] == group_ap_id(group),
           "named as the Lock was, or a receiver cannot tell which group's moderators to check"

    assert %{data: %{"type" => "Announce"}} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), undo),
           "the group passes it on to its followers"
  end

  # removing a post from the group takes the group's boost back, which other servers' copies of the group only learn of from the group's `Undo{Announce}`
  test "removing a post from the group federates the group's Undo of its Announce" do
    creator = fake_user!()
    group = public_group(creator)
    post = post_in_group(creator, group, "<p>a post the group will drop</p>")

    assert {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

    assert %{data: announce} =
             ActivityPub.Object.get_existing_announce(group_ap_id(group), ap_post),
           "control: the group announced it, so there is an Announce to undo"

    assert {:ok, _} = Bonfire.Classify.Categories.remove_post_from_group(creator, group, post)

    assert ActivityPub.Object
           |> repo().all()
           |> Enum.any?(
             &(&1.data["type"] == "Undo" and &1.data["actor"] == group_ap_id(group) and
                 ActivityPub.Object.get_ap_id(&1.data["object"]) == announce["id"])
           ),
           "the group took its boost back here but told nobody, so remote copies of the group keep showing the post"
  end

  # Lemmy ignores an `Undo{Announce}` (it is in neither inbox list), and removes a post from a community on a moderator's `Delete` carrying a `summary`. So removing someone's post from our group sends that too, relayed by the group, while the post itself stays here: the removal is from the group, not of the post
  test "a moderator removing a member's post from the group also sends a moderator's Delete with a reason, and keeps the post" do
    moderator = fake_user!()
    group = public_group(moderator)
    member = fake_user!()
    assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(member, group)

    post = post_in_group(member, group, "<p>a member's post the group will drop</p>")
    assert {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)
    assert {:ok, %{ap_id: moderator_ap_id}} = ActivityPub.Actor.get_cached(pointer: moderator)
    group_ap_id = group_ap_id(group)

    # no reason given, as the UI doesn't ask for one yet
    assert {:ok, _} = Bonfire.Classify.Categories.remove_post_from_group(moderator, group, post)

    assert %{
             data: %{
               "actor" => ^moderator_ap_id,
               "summary" => summary,
               "audience" => ^group_ap_id
             }
           } = delete = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete")

    assert is_binary(summary) and summary != "",
           "without a summary, Lemmy reads a Delete as the author deleting their own post"

    assert %{data: %{"type" => "Announce"}} =
             ActivityPub.Object.get_existing_announce(group_ap_id, delete),
           "relayed by the group, as every activity in a group we host"

    assert {:ok, _} = Bonfire.Common.Needles.get(id(post), skip_boundary_check: true),
           "removed from the group, not deleted"

    assert {:ok, %{data: %{"type" => type}}} = ActivityPub.Object.get_cached(ap_id: ap_id)
    refute type == "Tombstone", "and our own copy of its AP object stays as it was"
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

  # A group's ban is addressed to Public and to the group, and `Block` is not an addressed-only type, so besides the group it also went to the moderator's own remote followers. Mastodon, Pleroma and Akkoma read a `Block` that reaches their inbox, whatever its `target`, as the moderator blocking the person, so a banned person who follows the moderator from one of them lost that follow as a side effect. The group's relay is what tells the threadiverse
  describe "a group ban's delivery" do
    setup do
      mock(fn
        %{method: :get, url: @remote_actor} ->
          json(APSimulate.actor_json(@remote_actor))

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}
      end)

      moderator = fake_user!()
      group = public_group(moderator)
      person = fake_user!()
      {:ok, _} = Follows.follow(remote_follower(), moderator, skip_boundary_check: true)

      {:ok, moderator_actor} = ActivityPub.Actor.get_cached(pointer: moderator)
      {:ok, %{data: remote_data}} = ActivityPub.Actor.get_cached(ap_id: @remote_actor)

      {:ok,
       moderator: moderator,
       group: group,
       person: person,
       moderator_actor: moderator_actor,
       their_inboxes:
         Enum.reject(
           [remote_data["inbox"], e(remote_data, "endpoints", "sharedInbox", nil)],
           &is_nil/1
         )}
    end

    defp inboxes(actor, activity),
      do: APPublisher.prepare_publish_params(actor, activity) |> Enum.map(& &1.inbox)

    defp sent_by(moderator_actor, type) do
      Bonfire.Common.Repo.all(ActivityPub.Object)
      |> Enum.filter(&(&1.data["type"] == type and &1.data["actor"] == moderator_actor.ap_id))
    end

    test "control: a public post by the moderator does reach their remote follower", %{
      moderator: moderator,
      moderator_actor: moderator_actor,
      their_inboxes: their_inboxes
    } do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: moderator,
                 post_attrs: %{post_content: %{html_body: "<p>a post for my followers</p>"}},
                 boundary: "public"
               )

      {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)
      create = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Create")

      assert Enum.any?(inboxes(moderator_actor, create), &(&1 in their_inboxes)),
             "so the ban below not reaching them is the ban, not the fixture"
    end

    test "a ban goes to the group's side and not to the moderator's remote followers", %{
      moderator: moderator,
      moderator_actor: moderator_actor,
      group: group,
      person: person,
      their_inboxes: their_inboxes
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [ban] = sent_by(moderator_actor, "Block")
      assert ban.data["target"] == group_ap_id(group), "control: it is the group's ban"

      refute Enum.any?(inboxes(moderator_actor, ban), &(&1 in their_inboxes))
    end

    # The moderator's `Block` reaches the banned person's own instance only through the group's relay to its followers, and a block ghosts them, so the publisher skips them there. The group's own `Block` goes to them directly instead, for a block only: a ghost reads on the other side as the group blocking them, which a silence is not
    test "a block also sends the group's own Block straight to the banned person's instance", %{
      moderator: moderator,
      group: group,
      their_inboxes: their_inboxes
    } do
      banned = remote_follower()
      {:ok, group_actor} = ActivityPub.Actor.get_cached(pointer: group)
      {:ok, %{ap_id: banned_ap_id}} = ActivityPub.Actor.get_cached(pointer: banned)

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(banned, :block,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [own] = sent_by(group_actor, "Block")
      assert own.data["object"] == banned_ap_id
      assert banned_ap_id in List.wrap(own.data["to"]), "got #{inspect(own.data)}"
      refute Map.has_key?(own.data, "target"), "the group's own block, not a ban naming a group"

      assert Enum.any?(inboxes(group_actor, own), &(&1 in their_inboxes)),
             "delivered to their instance"
    end

    test "a silence sends only the moderator's Block", %{
      moderator: moderator,
      moderator_actor: moderator_actor,
      group: group
    } do
      banned = remote_follower()
      {:ok, group_actor} = ActivityPub.Actor.get_cached(pointer: group)

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(banned, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert [_] = sent_by(moderator_actor, "Block"), "control: the moderator's ban went out"
      assert sent_by(group_actor, "Block") == []
    end

    test "unbanning a block sends the group's Undo too", %{
      moderator: moderator,
      group: group,
      their_inboxes: their_inboxes
    } do
      banned = remote_follower()
      {:ok, group_actor} = ActivityPub.Actor.get_cached(pointer: group)

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(banned, :block,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.unblock(banned, :block,
                 current_user: moderator,
                 on_behalf_of: group
               )

      assert [undo] = sent_by(group_actor, "Undo")

      assert Enum.any?(inboxes(group_actor, undo), &(&1 in their_inboxes)),
             "delivered to their instance"
    end

    test "unbanning goes the same way", %{
      moderator: moderator,
      moderator_actor: moderator_actor,
      group: group,
      person: person,
      their_inboxes: their_inboxes
    } do
      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.unblock(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group
               )

      assert [undo] = sent_by(moderator_actor, "Undo")

      refute Enum.any?(inboxes(moderator_actor, undo), &(&1 in their_inboxes))
    end
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

    # someone on another instance who joined by `Join` alone (as Mobilizon does, never sending a `Follow`) is still delivered the group's relay of a deletion, since their join records them as a follower (`Categories.join_group/3`)
    test "a member who joined from another instance by Join alone gets the group's relay of a deletion" do
      creator = fake_user!()
      group = public_group(creator)
      remote_user = remote_follower()

      {:ok, _} =
        ActivityPub.Federator.Transformer.handle_incoming(%{
          "id" => @remote_actor <> "/join/#{System.unique_integer([:positive])}",
          "type" => "Join",
          "actor" => @remote_actor,
          "object" => group_ap_id(group),
          "to" => [group_ap_id(group)]
        })

      assert Bonfire.Classify.Categories.member?(remote_user, group), "control: joined"

      post = post_in_group(creator, group, "<p>soon gone</p>")
      {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)
      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: creator)

      delete = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete")
      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

      assert %{data: %{"type" => "Announce"}} =
               announce = ActivityPub.Object.get_existing_announce(actor.ap_id, delete),
             "control: the group relayed the deletion"

      {:ok, %{data: remote_data}} = ActivityPub.Actor.get_cached(ap_id: @remote_actor)
      their_inboxes = [remote_data["inbox"], e(remote_data, "endpoints", "sharedInbox", nil)]

      inboxes = APPublisher.prepare_publish_params(actor, announce) |> Enum.map(& &1.inbox)

      assert Enum.any?(inboxes, &(&1 in their_inboxes)),
             "the member's instance is among the relay's recipients"
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

    # Mastodon deletes a status only on a `Delete` from the account that wrote it, and a server that follows the GROUP and not the author knows the post only through the group's `Announce`. The author's `Delete` goes to the author's followers and the people it mentions, so without this that server keeps the deleted post, on the author's profile, for good. Found against `@mayel@mastodon.social` on 20 October (`group_account_live_test.exs`).
    test "the author's own Delete reaches the group's remote followers, who only know the post through the group" do
      creator = fake_user!()
      group = public_group(creator)
      {:ok, _} = Follows.follow(remote_follower(), group, skip_boundary_check: true)

      post = post_in_group(creator, group, "<p>soon gone, from every follower's server</p>")
      assert {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: creator)

      assert %{} = delete = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
             "control: the deletion federated a Delete"

      {:ok, author_actor} = ActivityPub.Actor.get_cached(pointer: creator)
      {:ok, %{data: remote_data}} = ActivityPub.Actor.get_cached(ap_id: @remote_actor)
      their_inboxes = [remote_data["inbox"], e(remote_data, "endpoints", "sharedInbox", nil)]

      deliveries = APPublisher.prepare_publish_params(author_actor, delete)

      assert Enum.any?(deliveries, &(&1.inbox in their_inboxes)),
             "the author's Delete went only to #{inspect(Enum.map(deliveries, & &1.inbox))}, so the group's remote follower never hears the post is gone"
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
