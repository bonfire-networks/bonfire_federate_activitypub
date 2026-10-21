defmodule Bonfire.Federate.ActivityPub.C2SCategoryTagsTest do
  @moduledoc """
  The tags of an `Event` that a local user posts to their own outbox (C2S).

  Nothing models an `Event`, so it is stored as an `APActivity` with the raw AS2 json, and the items of its `tag` have to become real tags there. See `plans/events-categories.md`.
  """
  # `@moduletag :federation` comes with this case
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Bonfire.Classify.Simulate

  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""

  setup do
    user = fake_user!()

    {:ok, conn: build_conn(), user: user, username: user.character.username}
  end

  defp event_doc(tags) do
    %{
      "type" => "Event",
      "name" => "Jazz Night",
      "content" => "Come along",
      "startTime" => "2026-08-21T15:47:13Z",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "tag" => tags
    }
  end

  # an event as Lauti emits it: its test "category and topic" (`service/activitypub/event_test.go` at 5b2c7b66, after Lauti renamed `HashTag` to `Hashtag`), with a concrete base URL, and without the `likes` and `shares` collections, which are not part of what a client posts
  defp lauti_event(base) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/fep/8a8e",
        "https://w3id.org/fep/9b2b",
        "https://schema.org",
        "https://purl.archive.org/miscellany"
      ],
      "type" => "Event",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "joinMode" => "none",
      "displayEndTime" => "false",
      "eventStatus" => "EventScheduled",
      "id" => base <> "/event/0",
      "url" => base <> "/event/0",
      "timezone" => "Europe/Berlin",
      "location" => %{"address" => "Placa 1", "name" => "Placa", "type" => "Place"},
      "name" => "may day",
      "content" => "solidarity will win",
      "organizers" => %{"totalItems" => 1, "items" => [%{"name" => "Rote Hilfe"}]},
      "startTime" => "2026-05-01T13:12:00Z",
      "tag" => [
        %{"type" => "Hashtag", "name" => "#mayday", "href" => base <> "?tags=mayday"},
        %{"type" => "Hashtag", "name" => "#solidarity", "href" => base <> "?tags=solidarity"},
        %{
          "id" => base <> "/category/0",
          "type" => "Category",
          "inScheme" => "https://w3id.org/fep/9b2b#Form",
          "name" => "bar",
          "content" => "bar description"
        },
        %{
          "id" => base <> "/topic/0",
          "type" => "Category",
          "inScheme" => "https://w3id.org/fep/9b2b#Topic",
          "name" => "foo",
          "content" => "foo description"
        }
      ],
      "image" => %{
        "type" => "Image",
        "url" => %{
          "type" => "Link",
          "href" => base <> "/api/v1/media/mayday.jpg",
          "name" => "a picture"
        }
      }
    }
  end

  # posts as the local user, as `actor_delegation_test.exs` does for a non-delegated client
  defp post_event(conn, user, username, tags),
    do: post_doc(conn, user, username, event_doc(tags))

  defp post_doc(conn, user, username, doc) do
    conn
    |> assign(:current_user, user)
    |> put_req_header("content-type", @content_type)
    |> post("#{ActivityPub.Utils.ap_base_url()}/actors/#{username}/outbox", doc)
  end

  # the `APActivity` that the posted `Event` became, with its tags
  defp posted_activity(conn) do
    resp = json_response(conn, 201)

    object_ap_id =
      case resp["object"] do
        %{"id" => id} -> id
        id when is_binary(id) -> id
      end

    {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)

    assert object.pointer_id,
           "the AP object was stored but never linked to an object on the host"

    object.pointer_id
    |> Bonfire.Common.Needles.get!(skip_boundary_check: true)
    |> repo().maybe_preload(tags: [:named, :character])
  end

  # the tags of the activity that are categories, as the categories themselves
  defp tagged_categories(activity) do
    activity.tags
    |> Enum.map(&Bonfire.Common.Needles.get!(&1.id, skip_boundary_check: true))
    |> Enum.filter(&match?(%Bonfire.Classify.Category{}, &1))
    |> repo().maybe_preload(:profile)
  end

  describe "a local user's Event posted to their outbox" do
    # a baseline, expected GREEN before any change: nothing tests `maybe_cast_tags` today (`hashtag_handling_test.exs` covers Posts only), and every later step edits it
    test "has its Hashtag tag tagged", %{conn: conn, user: user, username: username} do
      conn = post_event(conn, user, username, [%{"type" => "Hashtag", "name" => "#jazz"}])

      assert conn.status == 201

      assert %Bonfire.Data.Social.APActivity{} = activity = posted_activity(conn)

      hashtag_names =
        activity.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "jazz" in hashtag_names
    end

    test "has the local topic its Category tag names tagged",
         %{conn: conn, user: user, username: username} do
      topic = fake_category!(user, nil, %{type: :topic, name: "Jazz"})
      iri = Bonfire.Me.Characters.character_url(topic)

      conn =
        post_event(conn, user, username, [%{"type" => "Category", "id" => iri, "name" => "Jazz"}])

      assert conn.status == 201

      assert %Bonfire.Data.Social.APActivity{} = activity = posted_activity(conn)

      assert topic.id in Enum.map(activity.tags, & &1.id)
    end

    test "has a new local topic tagged for a Category tag with no id",
         %{conn: conn, user: user, username: username} do
      conn = post_event(conn, user, username, [%{"type" => "Category", "name" => "Poetry"}])

      assert conn.status == 201

      assert [topic] = conn |> posted_activity() |> tagged_categories()

      assert topic.type == :topic
      assert topic.profile.name == "Poetry"
    end

    test "has a new local topic tagged for a Category tag whose id is not ours, and does not keep that id",
         %{conn: conn, user: user, username: username} do
      iri = "https://lauti.example/category/0"

      conn =
        post_event(conn, user, username, [
          %{"type" => "Category", "id" => iri, "name" => "Poetry"}
        ])

      assert conn.status == 201

      assert [topic] = conn |> posted_activity() |> tagged_categories()

      assert topic.type == :topic
      assert topic.profile.name == "Poetry"
      assert {:error, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(iri)
    end

    test "tags a Lauti event's hashtags and makes a local topic of each of its categories",
         %{conn: conn, user: user, username: username} do
      conn = post_doc(conn, user, username, lauti_event("https://lauti.example"))

      assert conn.status == 201

      activity = posted_activity(conn)

      hashtag_names =
        activity.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "mayday" in hashtag_names
      assert "solidarity" in hashtag_names

      topics = tagged_categories(activity)

      assert ["bar", "foo"] == topics |> Enum.map(& &1.profile.name) |> Enum.sort()
      assert Enum.all?(topics, &(&1.type == :topic))
    end

    test "puts a Lauti event in the feed of each topic made from its categories",
         %{conn: conn, user: user, username: username} do
      conn = post_doc(conn, user, username, lauti_event("https://lauti.example"))

      assert conn.status == 201

      activity = posted_activity(conn)

      topics = activity |> tagged_categories() |> repo().maybe_preload(:character)

      # the precondition: both topics exist, so the loop below checks two feeds and not none
      assert ["bar", "foo"] == topics |> Enum.map(& &1.profile.name) |> Enum.sort()

      for topic <- topics do
        feed =
          Bonfire.Social.FeedLoader.feed(%{feed_ids: [topic.character.outbox_id]},
            current_user: user
          )

        assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity, current_user: user),
               "the event is not in the feed of the topic #{topic.profile.name}"
      end
    end

    test "reuses the topics of an earlier post of the same categories, and makes none new",
         %{conn: conn, user: user, username: username} do
      topic_ids = fn conn ->
        conn |> posted_activity() |> tagged_categories() |> Enum.map(& &1.id) |> Enum.sort()
      end

      first = post_doc(conn, user, username, lauti_event("https://lauti.example"))
      assert first.status == 201

      second = post_doc(build_conn(), user, username, lauti_event("https://lauti.example"))
      assert second.status == 201

      first_ids = topic_ids.(first)

      assert length(first_ids) == 2
      assert first_ids == topic_ids.(second)
    end

    # not built yet: `content` is where Lauti puts a category's description (9b2b says `summary`), and the topic is made from the name alone, so it has no summary. Parked until the topics are made from the whole item.
    @tag :skip
    test "keeps the description of a Lauti category as the summary of its topic",
         %{conn: conn, user: user, username: username} do
      conn = post_doc(conn, user, username, lauti_event("https://lauti.example"))

      assert conn.status == 201

      summaries =
        conn |> posted_activity() |> tagged_categories() |> Enum.map(& &1.profile.summary)

      assert ["bar description", "foo description"] == Enum.sort(summaries)
    end

    # records the defaults of open point 3a of `plans/events-categories.md`: the poster is the creator of the topic, so holds `:administer` and may tag it, and the default boundary of a top-level topic lets every local user follow it but not tag it
    test "creates a topic that its poster may tag, and any other local user may follow but not tag",
         %{conn: conn, user: user, username: username} do
      other = fake_user!()

      conn = post_event(conn, user, username, [%{"type" => "Category", "name" => "Poetry"}])

      assert [topic] = conn |> posted_activity() |> tagged_categories()

      assert Bonfire.Boundaries.can?(user, :tag, topic)
      assert Bonfire.Boundaries.can?(other, :follow, topic)
      refute Bonfire.Boundaries.can?(other, :tag, topic)
    end

    test "is in the feed of the topic it made from its Category tag",
         %{conn: conn, user: user, username: username} do
      conn = post_event(conn, user, username, [%{"type" => "Category", "name" => "Poetry"}])

      activity = posted_activity(conn)
      assert [topic] = tagged_categories(activity)

      topic = repo().maybe_preload(topic, :character)

      feed =
        Bonfire.Social.FeedLoader.feed(%{feed_ids: [topic.character.outbox_id]},
          current_user: user
        )

      assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity, current_user: user)
    end

    test "is in the feed of the topic its Category tag names, when the poster may tag the topic",
         %{conn: conn, user: user, username: username} do
      topic =
        fake_category!(user, nil, %{type: :topic, name: "Jazz"})
        |> repo().maybe_preload(:character)

      iri = Bonfire.Me.Characters.character_url(topic)

      conn =
        post_event(conn, user, username, [%{"type" => "Category", "id" => iri, "name" => "Jazz"}])

      assert conn.status == 201
      activity = posted_activity(conn)

      feed =
        Bonfire.Social.FeedLoader.feed(%{feed_ids: [topic.character.outbox_id]},
          current_user: user
        )

      assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity, current_user: user)
    end

    test "is tagged but not in the feed of a topic the poster may not tag",
         %{conn: conn, user: user, username: username} do
      owner = fake_user!()

      topic =
        fake_category!(owner, nil, %{type: :topic, name: "Jazz"})
        |> repo().maybe_preload(:character)

      iri = Bonfire.Me.Characters.character_url(topic)

      # the precondition, so that what is refused below is the `:tag` permission and not something else
      refute Bonfire.Boundaries.can?(user, :tag, topic)

      conn =
        post_event(conn, user, username, [%{"type" => "Category", "id" => iri, "name" => "Jazz"}])

      assert conn.status == 201
      activity = posted_activity(conn)

      assert topic.id in Enum.map(activity.tags, & &1.id)

      feed =
        Bonfire.Social.FeedLoader.feed(%{feed_ids: [topic.character.outbox_id]},
          current_user: owner
        )

      refute Bonfire.Social.FeedLoader.feed_contains?(feed, activity, current_user: owner)
    end

    test "tags the existing local topic, and creates none, when the name matches one named by its id",
         %{conn: conn, user: user, username: username} do
      topic = fake_category!(user, nil, %{type: :topic, name: "Jazz"})
      iri = Bonfire.Me.Characters.character_url(topic)

      conn =
        post_event(conn, user, username, [%{"type" => "Category", "id" => iri, "name" => "Jazz"}])

      assert conn.status == 201

      assert [%{id: id}] = conn |> posted_activity() |> tagged_categories()
      assert id == topic.id
    end
  end
end
