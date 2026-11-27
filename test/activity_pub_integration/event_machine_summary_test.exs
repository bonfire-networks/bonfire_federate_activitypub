# native events only exist with `bonfire_gatherings`, which a flavour may not include (its structs then do not compile)
if Bonfire.Common.Extend.extension_enabled?(:bonfire_gatherings) do
  defmodule Bonfire.Federate.ActivityPub.EventMachineSummaryTest do
    @moduledoc """
    The `summary` of an incoming `Event` is the machine-made when-and-where text that Gancio, Mobilizon and the WordPress Event Bridge write for Mastodon, never a content warning: the event shows with its `content` as the description. A `Note` with a `summary` keeps its content warning. An event with no valid time zone gets one from its start time's offset.
    """
    use Bonfire.Federate.ActivityPub.ConnCase, async: false
    @moduletag :federation
    import Tesla.Mock

    alias Bonfire.Common.Repo
    alias Bonfire.Gatherings.Event

    @public "https://www.w3.org/ns/activitystreams#Public"
    @note_actor "https://mocked.local/users/karen"

    # {fixture, a snippet of its `content`, a snippet only its `summary` has (nil when both say the same)}
    @fixtures [
      {"gancio/event-place.json", "Come along to the book launch", "Hopton Street Friday"},
      {"mobilizon/event-banner-nolocation.json", "Flowers in the Park", "November 14, 2027"},
      {"mobilizon/group-event-place.json", "humantalks-lyon", "November 9, 2027"},
      {"mobilizon/group-event-address-in-name.json", "Jam sessions au Music bar",
       "12 novembre 2027"},
      {"wordpress/eventbridge-update-event.json", "Is it working?", nil}
    ]

    setup_all do
      actors =
        for {file, _, _} <- @fixtures,
            object = fixture_object(file),
            actor <- [object["actor"], object["attributedTo"]],
            is_binary(actor),
            do: actor

      mock_global(fn
        %{method: :get, url: url} = env ->
          cond do
            url == @note_actor ->
              json(Simulate.actor_json(url))

            url in actors ->
              json(
                Simulate.actor_json(
                  url,
                  url |> String.split("/") |> List.last() |> String.trim_leading("@")
                )
              )

            String.contains?(url, "/.well-known/") ->
              %Tesla.Env{status: 404, body: ""}

            true ->
              apply(ActivityPub.Test.HttpRequestMock, :request, [env])
          end

        env ->
          apply(ActivityPub.Test.HttpRequestMock, :request, [env])
      end)

      :ok
    end

    setup do
      Process.put(:federating, true)
      Process.put(:req_adapter, fn request -> {request, Req.Response.new(status: 404)} end)
      account = fake_account!()
      me = fake_user!(account)
      {:ok, conn: conn(user: me, account: account)}
    end

    # as captured; an `Update` capture is read as its object
    defp fixture_object(file) do
      data =
        "../fixtures/#{file}"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      data["object"] || data
    end

    # the same event, years ahead so it is always upcoming, with the time zone offsets as sent
    defp upcoming(object) do
      for key <- ["startTime", "endTime"], is_binary(object[key]), reduce: object do
        acc -> Map.put(acc, key, String.replace(object[key], ~r/^\d{4}/, "2099"))
      end
    end

    defp receive_event!(object) do
      actor = object["actor"] || object["attributedTo"]

      {:ok, data} =
        ActivityPub.Federator.Transformer.handle_incoming(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "type" => "Create",
          "id" => object["id"] <> "/create",
          "actor" => actor,
          "to" => [@public],
          "object" => object
        })

      {:ok, event} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
      event
    end

    defp time_span(event),
      do: Repo.get!(Event, event.id) |> Repo.preload(:time_span) |> Map.fetch!(:time_span)

    for {file, content, preamble} <- @fixtures do
      describe "#{file}" do
        test "shows on the events page with no content warning and its content as the description",
             %{conn: conn} do
          object = unquote(file) |> fixture_object() |> upcoming()
          receive_event!(object)

          conn
          |> visit("/events")
          |> wait_async()
          |> assert_has_or_open_browser("[data-id=event_preview]", text: object["name"])
          |> refute_has("[data-id=event_preview] [data-role=cw]")
          |> assert_has_or_open_browser("[data-role=event_summary]", text: unquote(content))
          |> then(fn session ->
            if unquote(preamble),
              do: refute_has(session, "[data-role=event_summary]", text: unquote(preamble)),
              else: session
          end)
        end

        test "shows on its own page with no content warning and its content", %{conn: conn} do
          object = unquote(file) |> fixture_object() |> upcoming()
          event = receive_event!(object)

          conn
          |> visit("/discussion/#{event.id}")
          |> wait_async()
          |> assert_has_or_open_browser("[data-layout=page]", text: unquote(content))
          |> then(fn session ->
            if unquote(preamble),
              do: refute_has(session, "[data-layout=page]", text: unquote(preamble)),
              else: session
          end)
          |> refute_has("[data-role=cw]")
        end
      end
    end

    test "a Note with a summary keeps its content warning", %{conn: conn} do
      id = "https://mocked.local/notes/#{Needle.UID.generate()}"

      {:ok, data} =
        ActivityPub.Federator.Transformer.handle_incoming(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "type" => "Create",
          "id" => id <> "/create",
          "actor" => @note_actor,
          "to" => [@public],
          "object" => %{
            "type" => "Note",
            "id" => id,
            "attributedTo" => @note_actor,
            "summary" => "spoilers for the finale",
            "content" => "the butler did it",
            "to" => [@public]
          }
        })

      {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      conn
      |> visit("/feed/fediverse")
      |> wait_async()
      |> assert_has_or_open_browser("[data-role=cw]", text: "spoilers for the finale")
    end

    describe "time zone" do
      defp gancio, do: fixture_object("gancio/event-place.json") |> upcoming()

      test "a valid `timezone` wins over the offset" do
        assert time_span(receive_event!(gancio())).timezone == "Europe/Rome"
      end

      test "with none, a whole-hour offset gives the inverted Etc/GMT zone" do
        event = gancio() |> Map.delete("timezone") |> receive_event!()
        assert time_span(event).timezone == "Etc/GMT-1"
      end

      test "with an unknown one, the offset gives the zone" do
        event = gancio() |> Map.put("timezone", "Mars/Olympus") |> receive_event!()
        assert time_span(event).timezone == "Etc/GMT-1"
      end

      test "a negative offset gives a positive Etc/GMT zone" do
        event =
          gancio()
          |> Map.delete("timezone")
          |> Map.put("startTime", "2099-11-06T19:00:00-05:00")
          |> receive_event!()

        assert time_span(event).timezone == "Etc/GMT+5"
      end

      test "with none, Z gives no zone" do
        event =
          gancio()
          |> Map.delete("timezone")
          |> Map.put("startTime", "2099-11-06T19:00:00Z")
          |> receive_event!()

        assert time_span(event).timezone == nil
      end

      test "with none, a half-hour offset gives no zone" do
        event =
          gancio()
          |> Map.delete("timezone")
          |> Map.put("startTime", "2099-11-06T19:00:00+05:30")
          |> receive_event!()

        assert time_span(event).timezone == nil
      end
    end
  end
end
