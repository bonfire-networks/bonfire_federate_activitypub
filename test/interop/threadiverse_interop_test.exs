defmodule Bonfire.Federate.ActivityPub.ThreadiverseInteropTest do
  @moduledoc """
  Interop pass for the FEP-1b12 threadiverse: Lemmy, PieFed and NodeBB.

  All fixtures are REAL captures from public outboxes (2026-08-26), with every instance hostname rewritten to a `.local` stand-in so nothing here names a real instance or invites a test to reach one. Shapes, paths and ids are otherwise untouched. Provenance for re-capture lives in the group federation plan.

  **They share one wire shape, which is why this is one module rather than three.** Every item across all three outboxes is `Announce{Create{<object>}}` with `audience` set to the community, differing only in the inner object type (`Page` for Lemmy/PieFed, `Article`/`Note` for NodeBB).
  That makes our inbound gap a single fix rather than one per implementor.

  The opposite pole is the mention-triggered bot-group family (`fedigroups_interop_test.exs`):

  | | FediGroups | threadiverse |
  |---|---|---|
  | `Announce.object` | bare id string | embedded `Create` activity |
  | group addressed via | `cc` + `Mention` tag | community in `to` AND `audience` |
  | thread starter | untitled `Note` | `Page` (Lemmy/PieFed) or `Article` (NodeBB) with `name` |

  ⚠️ Mbin has an actor and an `Accept` here but no announce: the instances we tried return HTTP 500 to an unauthenticated actor fetch and serve an EMPTY outbox to a signed one, so an Mbin announce can only be captured by following a magazine and receiving a delivery.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @fixtures Path.join([__DIR__, "..", "fixtures"])

  @implementors [
    # `titled` names the fixture used for title assertions. It matters that this is a TEXT post: a
    # Lemmy link post is a `Page` with an `attachment` and no `content`, which is genuinely media
    # rather than a titled post, so asserting a title on one would be testing the wrong thing.
    %{
      name: "Lemmy",
      dir: "lemmy",
      id: "https://lemmy.local/c/technology",
      actor: "community_actor.json",
      announces: ["announce_create_page.json", "announce_create_page_text.json"],
      titled: "announce_create_page_text.json"
    },
    # A second Lemmy community, because image posts are what it's for and `c/technology` has none: all 50 items in its outbox were links. Same software, so it adds no wire shape of its own, but it does carry the third payload kind (see the per-kind tests below).
    %{
      name: "Lemmy (image posts)",
      dir: "lemmy",
      id: "https://lemmy2.local/c/pics",
      actor: "community_actor_pics.json",
      announces: ["announce_create_page_image.json"],
      # an image post becomes Media rather than a titled post, so its title assertion lives in the per-kind tests below, against `metadata.json_ld` instead of `post_content`
      titled: nil
    },
    %{
      name: "PieFed",
      dir: "piefed",
      id: "https://piefed.local/c/piefed_meta",
      actor: "community_actor.json",
      announces: ["announce_create_page.json"],
      titled: "announce_create_page.json"
    },
    %{
      name: "NodeBB",
      dir: "nodebb",
      id: "https://nodebb.local/category/6",
      actor: "category_actor.json",
      announces: ["announce_create_article.json", "announce_create_note.json"],
      titled: "announce_create_article.json"
    },
    # ⚠️ No announce fixture: Mbin serves an EMPTY outbox (`{}`, HTTP 200) even to a SIGNED fetch of
    # a magazine local to the instance, so the outbox-capture technique that worked for the other
    # four yields nothing. An Mbin announce can only be captured by actually following the magazine
    # and receiving a delivery. Actor captured via a signed fetch from a public Bonfire instance.
    %{
      name: "Mbin",
      dir: "mbin",
      id: "https://mbin.local/m/testing",
      actor: "magazine_actor.json",
      announces: [],
      titled: nil
    }
  ]

  defp with_announces, do: Enum.filter(@implementors, &(&1.announces != []))

  # `titled: nil` means this implementor's fixture doesn't become a titled post at all (a Lemmy image
  # post becomes Media, whose title lives in `metadata.json_ld` — asserted in the per-kind tests)
  defp with_titled, do: Enum.filter(@implementors, &(&1.titled not in [nil, []]))

  setup do
    mock(fn
      %{method: :get, url: url} ->
        case served()[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      # outgoing deliveries (eg. the Follow in the handshake test) go nowhere, but must not raise
      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    :ok
  end

  describe "the community actor" do
    test "becomes a local group, with no rewrite allowlist needed" do
      for %{name: name, id: community} <- @implementors do
        assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => community})

        assert %Bonfire.Classify.Category{type: :group} = group,
               "#{name}: a `Group` actor says what it is, so it should need no rewrite"
      end
    end

    # A mirror without the community's own name and description is not browsable: people would be
    # asked to join "piefed_meta" with no idea what it is. All five captures carry both fields.
    test "keeps the community's name and description, so the mirror is browsable" do
      for %{name: name, id: community, dir: dir, actor: actor_file} <- @implementors do
        actor = fixture(dir, actor_file)

        assert actor["name"] && actor["summary"], "#{name}: fixture should carry both"

        assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => community})
        group = repo().maybe_preload(group, :profile)

        assert e(group, :profile, :name, nil) == actor["name"],
               "#{name}: a mirrored community should carry its own name"

        assert e(group, :profile, :summary, nil) == actor["summary"],
               "#{name}: and its own description"
      end
    end

    # A community can also reach us as the OBJECT of an activity rather than as an actor we went and
    # fetched. It is the same community either way, so it has to arrive with the same fields: this
    # path used to store the raw AS2 map and produce a group with no name, summary or policy.
    test "arrives complete when it comes as an activity's object rather than as an actor" do
      %{id: community, dir: dir, actor: actor_file} =
        Enum.find(@implementors, &(&1.name == "PieFed"))

      actor = fixture(dir, actor_file)

      assert {:ok, group} =
               Bonfire.Classify.Categories.ap_receive_activity(
                 nil,
                 %{data: %{"type" => "Create"}},
                 %{data: actor}
               )

      group = repo().maybe_preload(group, [:profile, character: [:peered]])

      assert e(group, :profile, :name, nil) == actor["name"],
             "a community named in an activity is still that community, with its own name"

      assert {:ok, fetched} = Adapter.maybe_create_remote_actor(%{"id" => community})

      assert fetched.id == group.id,
             "and it should be the SAME mirror we would have created by fetching the actor"
    end

    # `attributedTo` is how this family says who moderates, and it decides whether we can validate
    # their moderation as mod-listed rather than only same-origin. Membership of that circle carries
    # the `:moderate` grant, which is deliberate: see the decision in the group federation plan.
    test "the community's moderators become the mirrored group's moderators" do
      for %{name: name, id: community, dir: dir, actor: actor_file} <- @implementors do
        moderators = fixture(dir, actor_file)["attributedTo"]

        assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => community})

        assert Bonfire.Classify.Categories.moderators(group) != [],
               "#{name}: declares moderators at #{inspect(moderators)}, so the mirrored group should have some"
      end
    end

    # A community's own declarations change: moderators come and go, and it can start restricting
    # posting or requiring approval. Applying them only at creation would leave the mirror asserting
    # whatever it declared the day we first saw it. Lemmy re-syncs moderators on every fetch.
    test "a community's later changes are picked up, not just its first state" do
      %{id: community, dir: dir, actor: actor_file} =
        Enum.find(@implementors, &(&1.name == "Lemmy"))

      assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => community})

      refute Bonfire.Boundaries.Presets.group_dimension_slugs(group)[:participation] ==
               "moderators",
             "the captured actor has `postingRestrictedToMods: false`"

      restricted =
        fixture(dir, actor_file)
        |> Map.put("postingRestrictedToMods", true)

      Bonfire.Federate.ActivityPub.Adapter.update_remote_actor(group, restricted)

      {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(reloaded)[:participation] ==
               "moderators",
             "a community that starts restricting posting to moderators should restrict it here too"
    end

    # Joining a threadiverse community IS a Follow, answered with an `Accept` carrying the original Follow embedded rather than referenced by id. The fixture is a real Mbin `Accept` of a Follow our dev instance sent, and the four NodeBB Accepts we captured are the same shape, so one covers the handshake for both.
    test "the community's Accept of our Follow is understood" do
      follower = fake_user!()
      {:ok, follower_actor} = ActivityPub.Actor.get_cached(pointer: follower)

      %{id: community} = Enum.find(@implementors, &(&1.name == "Mbin"))
      {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => community})

      # a follow of a remote actor stays a request until they answer, which is the state the Accept
      # is supposed to resolve
      assert {:ok, request} = Bonfire.Social.Graph.Follows.follow(follower, group)
      refute Bonfire.Social.Graph.Follows.following?(follower, group)

      follow_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(request)

      # bind the captured Accept to this run's Follow, keeping Mbin's own fields (its `f/object` id,
      # the kbin `@context`, and the `state: "pending"` it adds to the embedded Follow)
      accept =
        fixture("mbin", "accept_follow.json")
        |> put_in(["object", "id"], follow_activity.data["id"])
        |> put_in(["object", "actor"], follower_actor.ap_id)

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(accept)

      assert Bonfire.Social.Graph.Follows.following?(follower, group),
             "an Accept of our Follow should leave us following the community"
    end
  end

  describe "the announced post" do
    test "is ingested and lands in the community's feed" do
      for %{name: name, dir: dir, id: community, announces: [announce_file | _]} <-
            with_announces() do
        announce = fixture(dir, announce_file)
        object = announce["object"]["object"]

        receive_announce(announce)

        group = AdapterUtils.get_character_by_ap_id!(community)
        post = announced_post!(name, object["id"])

        assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
                 by: group,
                 current_user: group
               ),
               "#{name}: the announced #{object["type"]} should land in the community's feed"
      end
    end

    test "keeps its title and original author" do
      for %{name: name, dir: dir, titled: announce_file} <- with_titled() do
        announce = fixture(dir, announce_file)
        object = announce["object"]["object"]

        receive_announce(announce)
        post = announced_post!(name, object["id"])

        assert e(post, :post_content, :name, nil) == object["name"],
               "#{name}: `name` is a real title on these thread starters and must survive ingest"

        assert URIs.canonical_url(e(post, :created, :creator, nil)) == object["attributedTo"],
               "#{name}: attribution belongs to the author, not the announcing community"
      end
    end
  end

  # `commentsEnabled` is how this family states a thread's reply status ON THE POST, where `Lock` states a change to it. Both mean the same thing locally, so both end in the same `:lock` block: this is the case of a thread that was already closed when we first saw it, which is what a backfill or a first fetch of an old thread looks like.
  describe "a thread closed to replies" do
    test "arrives closed when the post says comments are disabled" do
      someone = fake_user!()
      announce = fixture("piefed", "announce_create_page.json")

      assert announce["object"]["object"]["commentsEnabled"] == true,
             "the capture should start open, or the two halves of this test are the same case"

      # the captured post, unmodified: the control, without which "closed" and "never ingested at
      # all" are the same observation
      receive_announce(announce)
      open = announced_post!("PieFed", announce["object"]["object"]["id"])

      assert Bonfire.Boundaries.can?(someone, :reply, open),
             "a post with comments enabled should be repliable"

      # the same announce with comments disabled. A flipped field rather than a capture, because a
      # community outbox only announces a post as it is CREATED, so an already-closed thread is not
      # something an outbox can hand us
      closed_announce =
        announce
        |> variant_of("closed")
        |> put_in(["object", "object", "commentsEnabled"], false)

      receive_announce(closed_announce)
      closed = announced_post!("PieFed", closed_announce["object"]["object"]["id"])

      refute Bonfire.Boundaries.can?(someone, :reply, closed),
             "`commentsEnabled: false` closes a thread to replies, exactly as an incoming `Lock` does"
    end

    # A link post becomes `Bonfire.Files.Media` rather than a `Post`, and it is still a thread people
    # reply to, so it has to honour the same field. This is what makes the handling live at the
    # ingest seam instead of in `Bonfire.Posts`: link posts are most of what Lemmy federates, so
    # reading the field only for posts would miss the common case.
    test "including when the post is a link, which becomes Media rather than a Post" do
      someone = fake_user!()

      # the field is not in this capture, since the thread we captured is open. Added rather than
      # captured, because what is under test is our handling of a closed thread that lands as Media,
      # not whether a given capture carries the field
      closed_announce =
        fixture("lemmy", "announce_create_page.json")
        |> variant_of("closed")
        |> put_in(["object", "object", "commentsEnabled"], false)

      receive_announce(closed_announce)
      closed = announced_post!("Lemmy link", closed_announce["object"]["object"]["id"])

      assert %Bonfire.Files.Media{} = closed,
             "a link post is media, which is the whole point of this case"

      refute Bonfire.Boundaries.can?(someone, :reply, closed),
             "media carries the `replied` mixin, so a closed link thread must close here too"
    end
  end

  # NodeBB is the only one of the three whose community outbox carries replies at all — Lemmy and
  # PieFed outboxes list only top-level posts.
  test "NodeBB: an announced reply keeps its inReplyTo" do
    announce = fixture("nodebb", "announce_create_note.json")
    note = announce["object"]["object"]

    assert note["inReplyTo"], "fixture should be a reply"

    receive_announce(announce)
    post = announced_post!("NodeBB", note["id"])

    assert e(post, :replied, :reply_to_id, nil),
           "an announced reply should be threaded locally, not orphaned"
  end

  # Lemmy gives every thread starter the same `Page` type, so the KIND of post is carried entirely by the payload, and each kind has to be pinned separately — that is what decides whether replies and threading work on it locally. Captured from `lemmy.world/c/technology` and `/c/pics`:
  #
  # | kind  | `content` | `attachment`                                  | `image`            |
  # |-------|-----------|-----------------------------------------------|--------------------|
  # | text  | yes       | `[]`                                          | no                 |
  # | link  | optional  | `[{type: "Link", href, mediaType: text/html}]` | Lemmy-hosted thumb |
  # | image | yes       | `[{type: "Image", url}]` — `url`, NOT `href`   | Lemmy-hosted thumb |
  #
  # `image` is always Lemmy's own re-hosted copy, never the source: for a link post it thumbnails the article's preview image, for an image post it thumbnails the attached image itself.
  describe "each kind of Lemmy payload" do
    test "a text thread starter becomes a post you can reply to" do
      text = fixture("lemmy", "announce_create_page_text.json")
      receive_announce(text)

      obj = announced_post!("Lemmy text", text["object"]["object"]["id"])

      assert e(obj, :post_content, :html_body, nil),
             "a self-post has a body, so it should be a post you can reply to, not an attachment"
    end

    test "a link thread starter becomes media, keeping its title" do
      link = fixture("lemmy", "announce_create_page.json")
      object = link["object"]["object"]

      assert object["name"], "fixture should carry a title"

      receive_announce(link)
      obj = announced_post!("Lemmy link", object["id"])

      assert %Bonfire.Files.Media{} = obj,
             "a link post is genuinely media: a title plus a URL"

      json = e(obj, :metadata, "json_ld", nil) || e(obj, :metadata, :json_ld, nil)

      assert json["name"] == object["name"],
             "a link post is titled too, so the title has to survive into the media metadata"
    end

    # An image post also becomes Media, but unlike a bare link it carries a title AND a body that people actually read. Media keeps those in `metadata.json_ld`, so what matters is that they SURVIVE ingest and stay available to whatever renders the media preview, losing them here would be losing the post's actual content, not just a caption.
    test "an image thread starter keeps its title and body in its media metadata" do
      image = fixture("lemmy", "announce_create_page_image.json")
      object = image["object"]["object"]

      assert object["attachment"] |> List.first() |> Map.get("type") == "Image",
             "fixture should be an image post"

      assert object["name"] && object["content"],
             "fixture should carry both a title and a body"

      receive_announce(image)
      obj = announced_post!("Lemmy image", object["id"])

      assert %Bonfire.Files.Media{} = obj

      json = e(obj, :metadata, "json_ld", nil) || e(obj, :metadata, :json_ld, nil)

      assert json, "the announced object should be kept as media metadata, not discarded"

      assert json["name"] == object["name"],
             "an image post has a real title and it has to reach the preview component"

      assert json["content"] == object["content"],
             "an image post's body is its content, so it must survive ingest"

      # preserving it isn't enough on its own: `MediaLinkLive` renders the title via
      # `Media.media_label/1` and the body via `Media.description/1`, so both have to resolve or the
      # post's text is stored but invisible
      assert Bonfire.Files.Media.media_label(obj) == object["name"],
             "the title has to reach the media preview component"

      assert Bonfire.Files.Media.description(obj) == object["content"],
             "the body has to reach the media preview component"
    end
  end

  # A relay is an obvious way to launder blocked content: if unwrapping bypassed MRF, any blocked instance could still reach us by getting a group to announce its posts. MRF runs inside `Object.insert/4`, which the unwrapped inner activity goes through like any other Create, so it should be filtered, asserted rather than assumed.
  test "a blocked author's instance cannot reach us via a group relay" do
    %{dir: dir, titled: titled} = Enum.find(@implementors, &(&1.name == "Lemmy"))
    announce = fixture(dir, titled)
    object = announce["object"]["object"]
    author_host = URI.parse(object["attributedTo"]).host

    # `ActivityPub.Config`, which is where the MRF policies read boundaries from
    original = ActivityPub.Config.get(:boundaries, [])
    ActivityPub.Config.put(:boundaries, block: [author_host], silence_them: [], ghost_them: [])

    try do
      receive_announce(announce)

      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: object["id"]),
             "a relayed post from a blocked instance must not be ingested"
    after
      ActivityPub.Config.put(:boundaries, original)
    end
  end

  # Boundaries derived from what the community declares (`Categories.create_remote/2`). Both flags
  # occur in the wild: announcement-style communities really do set `postingRestrictedToMods: true`, but
  # since each is a single boolean, flipping it on a real captured actor covers the permutations
  # without four more fixture files.
  test "every permutation of the declared flags maps to the right boundaries" do
    for {name, _overrides, expected} <- boundary_variants() do
      assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => variant_id(name)})

      dims = Bonfire.Boundaries.Presets.group_dimension_slugs(group)

      for {dim, want} <- expected do
        assert dims[dim] == want,
               "#{name}: expected #{dim} to be #{inspect(want)}, got #{inspect(dims[dim])} (full dims: #{inspect(dims)})"
      end
    end
  end

  # ------------------------------------------------------------------

  defp boundary_variants do
    [
      {"open", %{}, %{membership: "open", participation: "anyone"}},
      {"approve", %{"manuallyApprovesFollowers" => true}, %{membership: "on_request"}},
      {"modsonly", %{"postingRestrictedToMods" => true}, %{participation: "moderators"}},
      {"approve_modsonly",
       %{"manuallyApprovesFollowers" => true, "postingRestrictedToMods" => true},
       %{membership: "on_request", participation: "moderators"}}
    ]
  end

  defp variant_id(name), do: "https://lemmy.local/c/variant_#{name}"

  # everything the mock serves: each community actor, each announced object and its author, plus the
  # boundary-permutation variants
  defp served do
    from_implementors =
      Enum.flat_map(@implementors, fn imp ->
        objects =
          for file <- imp.announces do
            object = fixture(imp.dir, file)["object"]["object"]

            [
              {object["id"], object},
              {object["attributedTo"], author_actor(object["attributedTo"])}
            ]
          end
          |> List.flatten()

        actor = fixture(imp.dir, imp.actor)

        # Real captures, because the three differ in ways worth exercising: Lemmy's collection omits
        # `totalItems` entirely, PieFed's has it, and NodeBB's items are full inline actor objects
        # rather than id strings. Mbin has no capture, so it falls back to a minimal collection.
        moderators =
          case actor["attributedTo"] do
            url when is_binary(url) ->
              collection = moderators_collection(imp, url)

              [{url, collection}] ++
                for id <- collection["orderedItems"] || [],
                    is_binary(id),
                    do: {id, author_actor(id)}

            _ ->
              []
          end

        [{imp.id, actor}] ++ objects ++ moderators
      end)

    variants =
      Enum.map(boundary_variants(), fn {name, overrides, _expected} ->
        {variant_id(name), community_variant(name, overrides)}
      end)

    Map.new(from_implementors ++ variants)
  end

  defp community_variant(name, overrides) do
    ap_id = variant_id(name)

    fixture("lemmy", "community_actor.json")
    |> Map.merge(%{
      "id" => ap_id,
      "preferredUsername" => "variant_#{name}",
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox",
      "followers" => "#{ap_id}/followers"
    })
    |> Map.merge(overrides)
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  # An announce carries its ids all the way down, and two announces sharing them are one post to us,
  # so a variant of a captured fixture needs its own at every level or the second is deduped away.
  defp variant_of(announce, suffix) do
    announce
    |> Map.update!("id", &"#{&1}/#{suffix}")
    |> update_in(["object", "id"], &"#{&1}/#{suffix}")
    |> update_in(["object", "object", "id"], &"#{&1}/#{suffix}")
  end

  defp receive_announce(announce) do
    case ActivityPub.Federator.Transformer.handle_incoming(announce) do
      {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      {:error, _} -> :ok
    end
  end

  defp announced_post!(name, ap_id) do
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id),
           "#{name}: the announced object should be stored as an ap_object"

    refute is_nil(pointer_id), "#{name}: the announced object must be linked to a local record"

    Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)
    # `prune: true` because the implementors don't all land on the same local schema (a `Page` and an
    # `Article` need not become the same thing), so the assoc list has to be filtered per schema
    |> repo().maybe_preload(
      [
        :post_content,
        :activity,
        :replied,
        created: [creator: [character: [:peered]]]
      ],
      prune: true
    )
  end

  defp author_actor(ap_id) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => "Person",
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  # Mbin's magazine actor points at a moderators collection we never captured (its instance answers
  # unauthenticated fetches with 500), so stand in a minimal one rather than skip the implementor.
  defp moderators_collection(imp, url) do
    path = @fixtures |> Path.join(imp.dir) |> Path.join("moderators_collection.json")

    if File.exists?(path) do
      fixture(imp.dir, "moderators_collection.json")
    else
      %{"type" => "OrderedCollection", "id" => url, "orderedItems" => ["#{imp.id}/moderator1"]}
    end
  end

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
