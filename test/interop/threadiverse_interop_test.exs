defmodule Bonfire.Federate.ActivityPub.ThreadiverseInteropTest do
  @moduledoc """
  Interop pass for the FEP-1b12 threadiverse: Lemmy, PieFed and NodeBB.

  All fixtures are REAL captures from public outboxes (2026-08-26) — `lemmy.ml/c/technology`,
  `piefed.social/c/piefed_meta`, `community.nodebb.org/category/6`.

  **They share one wire shape, which is why this is one module rather than three.** Every item
  across all three outboxes is `Announce{Create{<object>}}` with `audience` set to the community,
  differing only in the inner object type (`Page` for Lemmy/PieFed, `Article`/`Note` for NodeBB).
  That makes our inbound gap a single fix rather than one per implementor.

  The opposite pole is the mention-triggered bot-group family (`fedigroups_interop_test.exs`):

  | | FediGroups | threadiverse |
  |---|---|---|
  | `Announce.object` | bare id string | embedded `Create` activity |
  | group addressed via | `cc` + `Mention` tag | community in `to` AND `audience` |
  | thread starter | untitled `Note` | `Page` (Lemmy/PieFed) or `Article` (NodeBB) with `name` |

  ⚠️ Mbin is missing here deliberately: `fedia.io` and `kbin.earth` both return HTTP 500 to an
  unauthenticated actor fetch, so its fixtures need the signed-fetch/tunnel path.
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
      id: "https://lemmy.ml/c/technology",
      actor: "community_actor.json",
      announces: ["announce_create_page.json", "announce_create_page_text.json"],
      titled: "announce_create_page_text.json"
    },
    # A second Lemmy community, because image posts are what it's for and `c/technology` has none: all 50 items in its outbox were links. Same software, so it adds no wire shape of its own, but it does carry the third payload kind (see the per-kind tests below).
    %{
      name: "Lemmy (image posts)",
      dir: "lemmy",
      id: "https://lemmy.world/c/pics",
      actor: "community_actor_pics.json",
      announces: ["announce_create_page_image.json"],
      # an image post becomes Media rather than a titled post, so its title assertion lives in the per-kind tests below, against `metadata.json_ld` instead of `post_content`
      titled: nil
    },
    %{
      name: "PieFed",
      dir: "piefed",
      id: "https://piefed.social/c/piefed_meta",
      actor: "community_actor.json",
      announces: ["announce_create_page.json"],
      titled: "announce_create_page.json"
    },
    %{
      name: "NodeBB",
      dir: "nodebb",
      id: "https://community.nodebb.org/category/6",
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
      id: "https://kbin.earth/m/testing",
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
    mock(fn %{method: :get, url: url} ->
      case served()[url] do
        nil -> %Tesla.Env{status: 404, body: ""}
        body -> json(body)
      end
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
  # occur in the wild — `lemmy.ml/c/announcements` really is `postingRestrictedToMods: true` — but
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

  defp variant_id(name), do: "https://lemmy.ml/c/variant_#{name}"

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

        [{imp.id, fixture(imp.dir, imp.actor)}] ++ objects
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

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
