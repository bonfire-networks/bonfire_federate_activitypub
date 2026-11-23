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

    # the configured categories with each one's `parent` and `label` set as given (by default none: flat, and all topics), rather than the flavour's defaults
    defp put_category_grouping(parents \\ %{}, labels \\ []) do
      categories =
        for {key, config} <-
              Bonfire.Common.Config.get([Bonfire.Gatherings.Events, :categories], []) do
          config = Keyword.drop(config, [:parent, :label])

          config =
            if parent = parents[to_string(key)], do: [{:parent, parent} | config], else: config

          config = if to_string(key) in labels, do: [{:label, true} | config], else: config
          {key, config}
        end

      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories], categories)
    end

    # the configured categories as they are, with these values made labels
    defp put_category_labels(labels) do
      categories =
        for {key, config} <-
              Bonfire.Common.Config.get([Bonfire.Gatherings.Events, :categories], []) do
          {key, if(to_string(key) in labels, do: Keyword.put(config, :label, true), else: config)}
        end

      Process.put([:bonfire_gatherings, Bonfire.Gatherings.Events, :categories], categories)
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
            Bonfire.Boundaries.Scaffold.Instance.mod_circle(),
            skip_boundary_check: true
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

        # no grouping, so each value is directly under the parent, and no labels, so each value is a topic
        put_category_grouping()

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

        Process.put(
          [:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_parent],
          "events"
        )

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
        Process.put(
          [:bonfire_gatherings, Bonfire.Gatherings.Events, :categories_parent],
          "events"
        )

        # and no labels, so each value is a topic
        put_category_grouping(%{"THEATRE" => "ARTS"})

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

      if !Bonfire.Common.Extend.extension_enabled?(:bonfire_label),
        do: @tag(skip: "needs bonfire_label")

      test "an FEP-8a8e value configured as a label is tagged as a label, under the Events label" do
        put_category_labels(["LGBTQ"])

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

      test "without the labels extension, an FEP-8a8e value configured as a label is tagged as a topic, under the parent" do
        # as on a flavour without `bonfire_label`: its config read through the process tree, so the epic's tasks see it too (`Bonfire.Common.Extend`'s per-process cache would not reach them)
        Process.put([:bonfire_label, :modularity], :disabled)

        put_category_labels(["LGBTQ"])

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

        assert [%{type: :topic} = topic] = categories(native_event!(event_id))
        assert topic.character.username == "lgbtq_events"

        # under its group's topic (LGBTQ under CAUSES, in the configured nesting), itself under the parent
        assert %{
                 parent_category: %{
                   character: %{username: "causes_events"},
                   parent_category: %{character: %{username: "events"}}
                 }
               } =
                 Repo.maybe_preload(topic,
                   parent_category: [:character, parent_category: [:character]]
                 )
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

      # the fixture event, with the fields Mobilizon sets for an event that is booked elsewhere (`joinMode: "external"`) or held online
      defp mobilizon_event_with(fields) do
        mobilizon_event()
        |> Map.put("id", "https://mobilizon.local/events/#{Needle.UID.generate()}")
        |> Map.merge(fields)
      end

      defp event_info(id),
        do: native_event!(id) |> Repo.preload(:extra_info) |> Map.get(:extra_info)

      test "keeps its external participation URL and its online address, and only those" do
        assert {:ok, %Event{id: booked_id}} =
                 mobilizon_event_with(%{
                   "joinMode" => "external",
                   "externalParticipationUrl" => "https://tickets.mobilizon.local/e/1"
                 })
                 |> receive_s2s()

        assert %{info: info} = event_info(booked_id)
        assert info == %{"external_participation_url" => "https://tickets.mobilizon.local/e/1"}

        assert {:ok, %Event{id: online_id}} =
                 mobilizon_event_with(%{"onlineAddress" => "https://meet.mobilizon.local/room"})
                 |> receive_s2s()

        assert %{info: %{"online_address" => "https://meet.mobilizon.local/room"} = info} =
                 event_info(online_id)

        refute Map.has_key?(info, "external_participation_url")
        refute Map.has_key?(info, "join_mode")
      end

      test "drops a participation URL or online address that is not an http(s) URL" do
        assert {:ok, %Event{id: id}} =
                 mobilizon_event_with(%{
                   "externalParticipationUrl" => "javascript:alert(1)",
                   "onlineAddress" => "come to the back garden"
                 })
                 |> receive_s2s()

        assert is_nil(event_info(id)), "no extra info row when nothing valid is left"
      end

      test "an event with neither has no extra info" do
        assert {:ok, %Event{id: id}} = receive_s2s(mobilizon_event())
        assert is_nil(event_info(id))
      end

      test "an Update changes them, and leaves other extra info alone" do
        id = "#{@actor}/objects/#{Needle.UID.generate()}"

        assert {:ok, %Event{id: event_id}} =
                 receive_wrapped(
                   "Create",
                   event_object(id, "booked", "2030-06-01T17:00:00Z", %{
                     "externalParticipationUrl" => "https://tickets.mobilizon.local/e/1",
                     "onlineAddress" => "https://meet.mobilizon.local/room"
                   })
                 )

        # something else kept in the same map
        %{info: info} = extra = event_info(event_id)

        assert {:ok, _} =
                 extra
                 |> Bonfire.Data.Identity.ExtraInfo.changeset(%{
                   info: Map.put(info, "other", "kept")
                 })
                 |> Repo.update()

        assert {:ok, _} =
                 receive_wrapped(
                   "Update",
                   event_object(id, "booked", "2030-06-01T17:00:00Z", %{
                     "externalParticipationUrl" => "https://tickets.mobilizon.local/e/2"
                   })
                 )

        # the online address is not in the Update, but the stored object keeps what an Update leaves out, so it is kept
        assert event_info(event_id).info == %{
                 "external_participation_url" => "https://tickets.mobilizon.local/e/2",
                 "online_address" => "https://meet.mobilizon.local/room",
                 "other" => "kept"
               }
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

    describe "an Event whose Place has an address but no coordinates" do
      setup do
        :meck.new(Bonfire.Geolocate.Geocode, [:passthrough, :no_link])
        on_exit(fn -> :meck.unload(Bonfire.Geolocate.Geocode) end)
        :ok
      end

      defp stub_geocoder(result),
        do: :meck.expect(Bonfire.Geolocate.Geocode, :coordinates, fn _query -> result end)

      defp geocoder_queries,
        do:
          :meck.history(Bonfire.Geolocate.Geocode)
          |> Enum.map(fn {_, {_, :coordinates, [q]}, _} -> q end)

      # the Place of the fixture event, with its own coordinates and address taken out and `fields` put in
      defp place_with(fields) do
        mobilizon_event()["location"]
        |> Map.drop(["geo", "address"])
        |> Map.put("id", "https://mobilizon.local/address/#{Needle.UID.generate()}")
        |> Map.merge(fields)
      end

      defp stored_point(event_id),
        do: native_event!(event_id).primary_geolocation.geolocation.geom

      @postal_address %{
        "type" => "PostalAddress",
        "streetAddress" => " 4 Rue des Ducs ",
        "postalCode" => nil,
        "addressLocality" => "Nantes",
        "addressRegion" => "Pays de la Loire",
        "addressCountry" => "France"
      }

      test "a PostalAddress is geocoded, the point stored longitude first" do
        stub_geocoder({:ok, %{lat: 47.2184, lon: -1.5536}})

        assert {:ok, %Event{id: id}} =
                 mobilizon_event_with(%{
                   "location" => place_with(%{"address" => @postal_address})
                 })
                 |> receive_s2s()

        assert %{coordinates: {-1.5536, 47.2184}} = stored_point(id)

        assert geocoder_queries() == ["4 Rue des Ducs, Nantes, Pays de la Loire, France"]
      end

      test "a plain string address (and a Place with no id) is geocoded the same" do
        stub_geocoder({:ok, %{lat: 45.07, lon: 7.69}})

        place = place_with(%{"address" => "Via Roma 1, Torino"}) |> Map.delete("id")

        assert {:ok, %Event{id: id}} =
                 mobilizon_event_with(%{"location" => place}) |> receive_s2s()

        assert %{coordinates: {7.69, 45.07}} = stored_point(id)
        assert geocoder_queries() == ["Via Roma 1, Torino"]
      end

      test "a Place with coordinates keeps them and is not geocoded" do
        stub_geocoder({:ok, %{lat: 0.0, lon: 0.0}})

        assert {:ok, %Event{id: id}} =
                 mobilizon_event_with(%{
                   "location" =>
                     place_with(%{
                       "address" => @postal_address,
                       "latitude" => 50.43,
                       "longitude" => -3.68
                     })
                 })
                 |> receive_s2s()

        assert %{coordinates: {-3.68, 50.43}} = stored_point(id)
        assert geocoder_queries() == []
      end

      test "a Place's `geo` is ignored: it is geocoded like any Place with no latitude and longitude" do
        stub_geocoder({:ok, %{lat: 48.8566, lon: 2.3522}})

        # the fixture's own Place, which has a `geo` (and a PostalAddress)
        assert mobilizon_event()["location"]["geo"]

        assert {:ok, %Event{id: id}} =
                 mobilizon_event_with(%{
                   "location" =>
                     Map.put(
                       mobilizon_event()["location"],
                       "id",
                       "https://mobilizon.local/address/#{Needle.UID.generate()}"
                     )
                 })
                 |> receive_s2s()

        assert %{coordinates: {2.3522, 48.8566}} = stored_point(id)
        assert [_] = geocoder_queries()
      end

      test "the same address (trimmed, any case) is geocoded once, and the next place reuses the point" do
        stub_geocoder({:ok, %{lat: 45.07, lon: 7.69}})

        assert {:ok, %Event{id: first}} =
                 mobilizon_event_with(%{
                   "location" => place_with(%{"address" => "Via Roma 1, Torino"})
                 })
                 |> receive_s2s()

        assert {:ok, %Event{id: second}} =
                 mobilizon_event_with(%{
                   "location" => place_with(%{"address" => "  VIA ROMA 1, TORINO "})
                 })
                 |> receive_s2s()

        assert %{coordinates: {7.69, 45.07}} = stored_point(first)
        assert %{coordinates: {7.69, 45.07}} = stored_point(second)
        assert geocoder_queries() == ["Via Roma 1, Torino"]
      end

      test "a name that is not a place (eg. Online) is not geocoded, a real name is" do
        stub_geocoder({:ok, %{lat: 50.43, lon: -3.68}})

        assert {:ok, %Event{id: online}} =
                 mobilizon_event_with(%{"location" => place_with(%{"name" => "Online"})})
                 |> receive_s2s()

        assert is_nil(stored_point(online))
        assert geocoder_queries() == []

        assert {:ok, %Event{id: real}} =
                 mobilizon_event_with(%{
                   "location" => place_with(%{"name" => "The Mansion, Totnes"})
                 })
                 |> receive_s2s()

        assert %{coordinates: {-3.68, 50.43}} = stored_point(real)
        assert geocoder_queries() == ["The Mansion, Totnes"]
      end

      test "a name that looks like a URL is not geocoded" do
        stub_geocoder({:ok, %{lat: 50.43, lon: -3.68}})

        for name <- ["https://meet.jit.si/abc", "zoom.us/j/123", "www.example"] do
          assert {:ok, %Event{id: id}} =
                   mobilizon_event_with(%{"location" => place_with(%{"name" => name})})
                   |> receive_s2s()

          assert is_nil(stored_point(id))
        end

        assert geocoder_queries() == []
      end

      test "a short name (up to 3 words, no comma) with a non-place word is not geocoded, a longer one or one with a comma is" do
        stub_geocoder({:ok, %{lat: 52.52, lon: 13.4}})

        for name <- ["Online event", "Zoom call", "Virtual meetup"] do
          assert {:ok, %Event{id: id}} =
                   mobilizon_event_with(%{"location" => place_with(%{"name" => name})})
                   |> receive_s2s()

          assert is_nil(stored_point(id))
        end

        assert geocoder_queries() == []

        assert {:ok, %Event{id: id}} =
                 mobilizon_event_with(%{
                   "location" => place_with(%{"name" => "Online Café, Berlin"})
                 })
                 |> receive_s2s()

        assert %{coordinates: {13.4, 52.52}} = stored_point(id)
        assert geocoder_queries() == ["Online Café, Berlin"]
      end

      test "when geocoding fails, the event is saved with no point and a warning names the address" do
        stub_geocoder({:error, nil})

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, %Event{id: id}} =
                     mobilizon_event_with(%{
                       "location" => place_with(%{"address" => "Nowhere Lane 9"})
                     })
                     |> receive_s2s()

            send(self(), {:event_id, id})
          end)

        assert_received {:event_id, id}
        assert %{name: _, geom: nil} = native_event!(id).primary_geolocation.geolocation
        assert log =~ "Could not geocode the address"
        assert log =~ "Nowhere Lane 9"
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
        |> post(
          "#{ActivityPub.Utils.ap_base_url()}/actors/#{user.character.username}/outbox",
          doc
        )
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

        assert @public in get_in(object.data, [
                 "interactionPolicy",
                 "canReply",
                 "automaticApproval"
               ])

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
        # the values' topics reserved, as the startup task does on an instance (it does nothing in tests, so a fresh test database has none)
        Bonfire.Gatherings.EventCategories.reserve_topics()

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
