# native events only exist with `bonfire_gatherings`, which a flavour may not include (its structs then do not compile)
if Bonfire.Common.Extend.extension_enabled?(:bonfire_gatherings) do
defmodule Bonfire.Federate.ActivityPub.EventIngestTest do
  @moduledoc """
  An incoming ActivityPub `Event` (server to server, or posted by a local user to their outbox) becomes a native `Bonfire.Gatherings.Event`, rather than an `APActivity`.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  import Tesla.Mock
  require Ecto.Query

  alias Bonfire.Common.Repo
  alias Bonfire.Gatherings.Event
  alias ActivityPub.Federator.Workers.PublisherWorker

  @actor "https://mocked.local/users/karen"
  # a second remote author, for what does not depend on who posted first
  @other_actor "https://mocked.local/users/kip"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      %{method: :get, url: "https://mocked.local/users/kip"} ->
        json(Simulate.actor_json("https://mocked.local/users/kip"))

      %{method: :get, url: "https://mocked.local/.well-known/" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  defp mobilizon_event do
    "../fixtures/mobilizon.org-event.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp receive_s2s(data) do
    {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)
    Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
  end

  # an S2S Create or Update of `object`, as the inbox worker passes it on
  defp receive_wrapped(type, object, actor \\ @actor) do
    result =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => type,
        "id" => "#{object["id"]}/#{String.downcase(type)}/#{Needle.UID.generate()}",
        "actor" => actor,
        "to" => [@public],
        "object" => object
      })

    # an Update is already passed to Bonfire by `handle_incoming` (through `ActivityPub.update`), so only a Create needs the explicit call
    case {type, result} do
      {"Create", {:ok, data}} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
      _ -> result
    end
  end

  defp event_object(id, name, start, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "Event",
        "id" => id,
        "attributedTo" => @actor,
        "name" => name,
        "content" => "an event",
        "startTime" => start,
        "to" => [@public]
      },
      extra
    )
  end

  defp native_event!(id) do
    Repo.get!(Event, id)
    |> Repo.preload([:post_content, :time_span, :tags, primary_geolocation: :geolocation])
  end

  defp apactivities_with_ap_id(ap_id) do
    Repo.all(
      Ecto.Query.from(a in Bonfire.Data.Social.APActivity,
        where: fragment("?->>'id' = ?", a.json, ^ap_id)
      )
    )
  end

  defp hashtag_names(event) do
    event.tags
    |> Repo.maybe_preload([:named, :character])
    |> Enum.reject(& &1.character)
    |> Enum.map(& &1.named.name)
    |> Enum.sort()
  end

  # the `Announce`s stored with a category as their actor (the boosts it sent out)
  defp announces_of(category) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: category.id)

    Repo.all(
      Ecto.Query.from(o in ActivityPub.Object,
        where:
          fragment("?->>'type' = 'Announce'", o.data) and
            fragment("?->>'actor' = ?", o.data, ^actor.ap_id)
      )
    )
  end

  # the categories among an event's tags
  defp categories(event) do
    event.tags
    |> Enum.map(&Bonfire.Common.Needles.get!(&1.id, skip_boundary_check: true))
    |> Enum.filter(&match?(%Bonfire.Classify.Category{}, &1))
    |> Repo.maybe_preload([:profile, :character, :created])
  end

  describe "an Event received server to server" do
    test "becomes a native event with its name, body, times, place and hashtags" do
      data = mobilizon_event()

      assert {:ok, %Event{id: id}} = receive_s2s(data)
      event = native_event!(id)

      assert event.post_content.name == "Mobilizon Launching Party"
      assert is_binary(event.post_content.html_body)
      assert DateTime.compare(event.time_span.has_beginning, ~U[2019-12-18 13:00:00Z]) == :eq
      assert DateTime.compare(event.time_span.has_end, ~U[2019-12-18 14:00:00Z]) == :eq
      assert %{geolocation: %{}} = event.primary_geolocation
      # hashtags are stored lowercased
      assert hashtag_names(event) == ["activitypub", "federation", "mobilizon", "party"]

      assert [] = apactivities_with_ap_id(data["id"])
    end

    test "an FEP-8a8e category becomes a mirror of that category, shared by the events that have it, which the instance's moderators administer" do
      mod = fake_user!()

      {:ok, _} =
        Bonfire.Boundaries.Circles.add_to_circles(
          mod,
          Bonfire.Boundaries.Scaffold.Instance.mod_circle()
        )

      # (a) the category of a remote event
      assert {:ok, %Event{id: first_id}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Jazz Night",
                   "2030-06-01T19:00:00Z",
                   %{"category" => "MUSIC"}
                 )
               )

      assert [music] = categories(native_event!(first_id))
      assert music.character.username == "music_events"
      assert music.profile.name == "Music"
      # assert {:ok, %{canonical_uri: "https://w3id.org/fep/8a8e/category#MUSIC"}} =
      #          Bonfire.Federate.ActivityPub.Peered.get_by_uri(
      #            "https://w3id.org/fep/8a8e/category#MUSIC"
      #          )
      #
      # refute Bonfire.Social.is_local?(music)
      # a topic of this instance, as its own events use the same values
      assert Bonfire.Social.is_local?(music)

      # its boost of a remote event is not sent out: only local events are announced to the topic's followers elsewhere
      # refute Enum.any?(all_enqueued(worker: PublisherWorker), fn %{args: args} ->
      #          get_in(args, ["activity", "type"]) == "Announce" or args["op"] == "announce"
      #        end),
      #        "a topic's boost of a remote event was queued for delivery"
      assert [] = announces_of(music)

      # (b) the same value, lowercased as Mobilizon sends it, from another remote author, is the same category
      assert {:ok, %Event{id: second_id}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@other_actor}/objects/#{Needle.UID.generate()}",
                   "Folk Night",
                   "2030-06-02T19:00:00Z",
                   %{"category" => "music", "attributedTo" => @other_actor}
                 ),
                 @other_actor
               )

      assert [%{id: same_id}] = categories(native_event!(second_id))
      assert same_id == music.id

      # (f) both events are in its feed, for a local user to read there
      feed =
        Bonfire.Social.FeedLoader.feed(%{feed_ids: [music.character.outbox_id]},
          current_user: mod
        )

      assert Bonfire.Social.FeedLoader.feed_contains?(feed, first_id, current_user: mod)
      assert Bonfire.Social.FeedLoader.feed_contains?(feed, second_id, current_user: mod)

      # (c) a value outside the 36 makes nothing
      assert {:ok, %Event{id: third_id}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Something Else",
                   "2030-06-03T19:00:00Z",
                   %{"category" => "NOT_A_KEY"}
                 )
               )

      assert [] = categories(native_event!(third_id))

      # (d) the instance's moderators administer it. Its remote creator is recorded, and gets no grant on it, but `can?` lets an object's creator through without a check, so that is not asserted
      # refute Bonfire.Boundaries.can?(music.created.creator_id, :edit, music)
      # assert music.created.creator_id
      # made from a remote event, it has no creator: the instance's moderators administer it
      refute e(music, :created, :creator_id, nil)
      assert Bonfire.Boundaries.can?(mod, :edit, music)
    end

    test "with a parent topic configured, an FEP-8a8e category's topic is made under it, and others may still read and follow it" do
      reader = fake_user!()

      # a category whose topic already exists, from before the parent was configured (it is by default, so set to none here)
      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_parent], "")
      # no grouping, so each value is directly under the parent
      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_nesting], %{})
      # and no labels, so each value is a topic
      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_as_labels], [])

      assert {:ok, %Event{}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Gig",
                   "2030-06-04T18:00:00Z",
                   %{"category" => "MUSIC"}
                 )
               )

      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_parent], "events")

      assert {:ok, %Event{}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Another Gig",
                   "2030-06-05T18:00:00Z",
                   %{"category" => "MUSIC"}
                 )
               )

      # the parent is made only when a category's topic is, so not for one that already has its topic
      assert {:error, _} = Bonfire.Classify.Categories.get("events", skip_boundary_check: true)

      assert {:ok, %Event{id: event_id}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Bake Off",
                   "2030-06-04T19:00:00Z",
                   %{"category" => "FOOD_DRINK"}
                 )
               )

      assert [topic] = categories(native_event!(event_id))
      assert topic.character.username == "food_drink_events"

      assert %{parent_category: %{character: %{username: "events"}}} =
               Repo.maybe_preload(topic, parent_category: [:character])

      assert Bonfire.Boundaries.can?(reader, :read, topic)
      assert Bonfire.Boundaries.can?(reader, :follow, topic)
    end

    test "an FEP-8a8e category's reserved topic is brought back by the first event that names it, under its parent, and the others stay reserved" do
      # its own grouping and parent, rather than the flavour's defaults
      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_parent], "events")

      Process.put(
        [:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_nesting],
        %{"ARTS" => ["THEATRE"]}
      )

      # and no labels, so each value is a topic
      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_as_labels], [])

      Bonfire.Gatherings.EventCategories.reserve_topics()

      assert {:ok, %{id: reserved_id}} =
               Bonfire.Classify.Categories.get_archived("theatre_events")

      assert {:ok, %Event{id: event_id}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Opening Night",
                   "2030-06-06T19:00:00Z",
                   %{"category" => "THEATRE"}
                 )
               )

      # the reserved one, not a new one beside it
      assert [%{id: ^reserved_id} = theatre] = categories(native_event!(event_id))
      assert theatre.character.username == "theatre_events"

      # under the parent, brought back too
      # assert %{parent_category: %{character: %{username: "events"}}} =
      #          Repo.maybe_preload(games, parent_category: [:character])
      # under its group's topic (THEATRE under ARTS, as set above), itself under the parent, both brought back too
      assert %{
               parent_category: %{
                 character: %{username: "arts_events"},
                 parent_category: %{character: %{username: "events"}}
               }
             } =
               Repo.maybe_preload(theatre,
                 parent_category: [:character, parent_category: [:character]]
               )

      # and counted as its child (the tree's counts are kept by insert and delete triggers, not by an update)
      assert %{tree: %{direct_children_count: 1}} =
               Repo.preload(
                 Repo.maybe_preload(theatre, :parent_category).parent_category,
                 :tree,
                 force: true
               )

      # the values no event named stay reserved
      assert {:ok, _} = Bonfire.Classify.Categories.get_archived("pets_events")
    end

    test "an FEP-8a8e value configured as a label is tagged as a label, under the Events label" do
      Process.put(
        [:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_as_labels],
        ["LGBTQ"]
      )

      assert {:ok, %Event{id: event_id}} =
               receive_wrapped(
                 "Create",
                 event_object(
                   "#{@actor}/objects/#{Needle.UID.generate()}",
                   "Pride Picnic",
                   "2030-06-07T12:00:00Z",
                   %{"category" => "LGBTQ"}
                 )
               )

      assert [%{type: :label} = label] = categories(native_event!(event_id))
      assert label.character.username == "lgbtq_events"

      assert %{tree: %{parent_id: "1ABE1SF0REVENTSANDGATHER1N"}} = Repo.preload(label, :tree)
    end

    test "with no end and a time zone, keeps the zone and has no end" do
      id = "#{@actor}/objects/#{Needle.UID.generate()}"

      assert {:ok, %Event{id: event_id}} =
               receive_wrapped(
                 "Create",
                 event_object(id, "open ended", "2030-06-01T17:00:00Z", %{
                   "timezone" => "Europe/Paris",
                   "displayEndTime" => "false"
                 })
               )

      assert %{has_end: nil, timezone: "Europe/Paris"} = native_event!(event_id).time_span
    end

    test "an Update changes the event, and leaves one" do
      id = "#{@actor}/objects/#{Needle.UID.generate()}"

      assert {:ok, %Event{id: event_id}} =
               receive_wrapped(
                 "Create",
                 event_object(id, "first name", "2030-06-01T17:00:00Z", %{
                   "tag" => [%{"type" => "Hashtag", "name" => "#salad"}]
                 })
               )

      assert hashtag_names(native_event!(event_id)) == ["salad"], "tagged as it arrived"

      assert {:ok, _} =
               receive_wrapped(
                 "Update",
                 event_object(id, "updated name", "2030-07-01T17:00:00Z", %{
                   "tag" => [%{"type" => "Hashtag", "name" => "#soup"}]
                 })
               )

      event = native_event!(event_id)
      assert event.post_content.name == "updated name"
      assert DateTime.compare(event.time_span.has_beginning, ~U[2030-07-01 17:00:00Z]) == :eq
      assert hashtag_names(event) == ["soup"]
      assert ActivityPub.Object.get_cached!(ap_id: id).pointer_id == event_id
    end

    # `commentsEnabled` is applied for any object at the ingest seam (`Bonfire.Social.Threads.ap_receive_comments_enabled/4`), as a `:lock` block, the boundary a `Lock` sets
    test "with comments disabled arrives locked, and with them enabled does not" do
      open = mobilizon_event()
      assert open["commentsEnabled"] == true
      assert {:ok, %Event{} = open_event} = receive_s2s(open)
      refute Bonfire.Boundaries.Blocks.is_blocked?(open_event, :lock)

      closed =
        mobilizon_event()
        |> Map.put("id", "https://mobilizon.local/events/#{Needle.UID.generate()}")
        |> Map.put("commentsEnabled", false)

      assert {:ok, %Event{} = closed_event} = receive_s2s(closed)
      assert Bonfire.Boundaries.Blocks.is_blocked?(closed_event, :lock)
    end

    test "not addressed to the public, is only readable by its recipients" do
      recipient = fake_user!()
      other = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      data = mobilizon_event() |> Map.put("to", [recipient_actor.ap_id])

      assert {:ok, %Event{id: id}} = receive_s2s(data)

      assert {:ok, _} = Bonfire.Gatherings.Events.read(id, current_user: recipient)
      assert {:error, _} = Bonfire.Gatherings.Events.read(id, current_user: other)
    end
  end

  describe "an Event a local user posts to their outbox (C2S)" do
    setup do
      user = fake_user!()
      {:ok, conn: build_conn(), user: user}
    end

    defp post_event(conn, user, doc) do
      conn
      |> assign(:current_user, user)
      |> put_req_header("content-type", @content_type)
      |> post("#{ActivityPub.Utils.ap_base_url()}/actors/#{user.character.username}/outbox", doc)
    end

    test "becomes a native event, and its Create is queued for delivery", %{
      conn: conn,
      user: user
    } do
      # keys, as a user who has published before has (a new one's are made at its first publish), so the stored document can be signed
      {:ok, _} =
        ActivityPub.Actor.get_cached!(pointer: user.id)
        |> ActivityPub.Safety.Keys.ensure_keys_present()

      conn =
        post_event(conn, user, %{
          "type" => "Event",
          "name" => "Jazz Night",
          "content" => "Come along",
          "startTime" => "2030-08-21T19:00:00Z",
          "timezone" => "Europe/Paris",
          "to" => [@public]
        })

      assert %{"id" => create_id} = resp = json_response(conn, 201)
      object_ap_id = with %{"id" => id} <- resp["object"], do: id

      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)
      assert %Event{} = event = native_event!(object.pointer_id)
      assert event.post_content.name == "Jazz Night"
      assert event.time_span.timezone == "Europe/Paris"

      # its boundary comes from its addressing (public here), and allows comments when the client says nothing about them
      assert Bonfire.Boundaries.can?(fake_user!(), :reply, event)

      # and the document sent out says so, filled in from that boundary as for a post made here, since the client did not
      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)
      assert object.data["commentsEnabled"] == true

      assert @public in get_in(object.data, ["interactionPolicy", "canReply", "automaticApproval"])

      # signed again over what was filled in, so the proof served and sent covers it
      assert %{"proof" => _, "commentsEnabled" => true} = object.data_received

      {:ok, create} = ActivityPub.Object.get_cached(ap_id: create_id)

      assert Enum.any?(all_enqueued(worker: PublisherWorker), fn %{args: args} ->
               args["op"] == "publish" and
                 (args["activity_id"] == create.id or
                    get_in(args, ["activity", "id"]) == create_id)
             end),
             "the C2S Create of the event was not queued for delivery"
    end

    test "with an FEP-8a8e category, is tagged with the mirror of that category, as a remote event is",
         %{conn: conn, user: user} do
      conn =
        post_event(conn, user, %{
          "type" => "Event",
          "name" => "Choir Practice",
          "content" => "Come along",
          "startTime" => "2030-08-22T19:00:00Z",
          "category" => "MUSIC",
          "to" => [@public]
        })

      resp = json_response(conn, 201)
      object_ap_id = with %{"id" => id} <- resp["object"], do: id
      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)

      assert [music] = categories(native_event!(object.pointer_id))
      assert music.character.username == "music_events"
      # refute Bonfire.Social.is_local?(music)
      assert Bonfire.Social.is_local?(music)
      # made from a local user's event, it is theirs
      # assert music.created.creator_id == user.id
      # reserved by the instance (its username kept for it), so it has no creator, whoever's event brings it back
      refute e(music, :created, :creator_id, nil)

      # and its boost of this local event is announced
      assert [_] = announces_of(music)
    end

    test "with a location that has no id, gets that place as its geolocation", %{
      conn: conn,
      user: user
    } do
      conn =
        post_event(conn, user, %{
          "type" => "Event",
          "name" => "Picnic",
          "content" => "Come along",
          "startTime" => "2030-08-23T12:00:00Z",
          "location" => %{
            "type" => "Place",
            "name" => "Riverside Park",
            "latitude" => 50.43,
            "longitude" => -3.68
          },
          "to" => [@public]
        })

      resp = json_response(conn, 201)
      object_ap_id = with %{"id" => id} <- resp["object"], do: id
      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)

      assert %{primary_geolocation: %{geolocation: %{name: "Riverside Park"} = geo}} =
               native_event!(object.pointer_id)

      assert %{lat: lat, long: long} = Bonfire.Geolocate.Geolocations.populate_coordinates(geo)
      assert_in_delta lat, 50.43, 0.001
      assert_in_delta long, -3.68, 0.001
    end

    test "keeps comments closed when the client says so", %{conn: conn, user: user} do
      conn =
        post_event(conn, user, %{
          "type" => "Event",
          "name" => "Quiet Night",
          "startTime" => "2030-08-22T19:00:00Z",
          "commentsEnabled" => false,
          "to" => [@public]
        })

      object_ap_id = with %{"id" => id} <- json_response(conn, 201)["object"], do: id
      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)
      event = native_event!(object.pointer_id)

      assert Bonfire.Boundaries.Blocks.is_blocked?(event, :lock)
      refute Bonfire.Boundaries.can?(fake_user!(), :reply, event)

      # what the client said is kept as it said it
      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)
      assert object.data["commentsEnabled"] == false
    end
  end
end
end
