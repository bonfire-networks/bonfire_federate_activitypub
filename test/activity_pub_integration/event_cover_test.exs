# native events only exist with `bonfire_gatherings`, which a flavour may not include (its structs then do not compile)
if Bonfire.Common.Extend.extension_enabled?(:bonfire_gatherings) do
  defmodule Bonfire.Federate.ActivityPub.EventCoverTest do
    @moduledoc """
    The image of an incoming `Event` is its cover, in the events page and in a feed, and its media are not listed beside the card. Mobilizon and Gancio send the banner as an `attachment`, which is not flagged as the primary image; a sender of an `image` gets it flagged.
    """
    use Bonfire.Federate.ActivityPub.ConnCase, async: false
    @moduletag :federation
    import Tesla.Mock

    @actor "https://mocked.local/users/karen"
    @public "https://www.w3.org/ns/activitystreams#Public"
    @banner "https://mocked.local/media/banner.png"
    @poster "https://mocked.local/media/poster.png"
    @stream "https://youtube.com/live/FNqRMKlybO8"
    @stream_title "Are you getting fired? Info session for workers in The Netherlands."

    alias Bonfire.Files.Media

    setup_all do
      mock_global(fn
        %{method: :get, url: @actor} ->
          json(Simulate.actor_json(@actor))

        %{method: :get, url: "https://mocked.local/.well-known/" <> _} ->
          %Tesla.Env{status: 404, body: ""}

        # the stream of an online event: YouTube serves its page, and answers 401 from oEmbed for a video with embedding turned off
        %{method: :get, url: "https://www.youtube.com/oembed" <> _} ->
          %Tesla.Env{status: 401, body: "Unauthorized"}

        %{method: :get, url: "https://youtube.com/live/" <> _} = env ->
          stream_page(env)

        %{method: :get, url: "https://www.youtube.com/live/" <> _} = env ->
          stream_page(env)

        env ->
          apply(ActivityPub.Test.HttpRequestMock, :request, [env])
      end)

      :ok
    end

    setup do
      Process.put(:federating, true)

      # Faviconic fetches a link preview's favicon with Req, which Tesla.Mock does not intercept: answer it here so no test reaches the network
      Process.put(:req_adapter, fn request -> {request, Req.Response.new(status: 404)} end)
      account = fake_account!()
      me = fake_user!(account)
      {:ok, conn: conn(user: me, account: account)}
    end

    defp stream_page(env) do
      %Tesla.Env{
        env
        | status: 200,
          headers: [{"content-type", "text/html"}],
          body: """
          <html><head>
            <title>#{@stream_title} - YouTube</title>
            <meta property="og:title" content="#{@stream_title}">
            <meta property="og:image" content="https://i.ytimg.com/vi/FNqRMKlybO8/maxresdefault.jpg">
          </head><body></body></html>
          """
      }
    end

    defp image(url),
      do: %{"type" => "Document", "mediaType" => "image/png", "url" => url, "name" => "a banner"}

    # a Create of an event as the inbox worker passes it on
    defp receive_event!(name, extra) do
      id = "https://mocked.local/events/#{Needle.UID.generate()}"

      object =
        Map.merge(
          %{
            "type" => "Event",
            "id" => id,
            "attributedTo" => @actor,
            "name" => name,
            "content" => "an event",
            "startTime" => "2030-09-20T18:00:00Z",
            "endTime" => "2030-09-20T22:00:00Z",
            "to" => [@public]
          },
          extra
        )

      {:ok, data} =
        ActivityPub.Federator.Transformer.handle_incoming(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "type" => "Create",
          "id" => id <> "/create",
          "actor" => @actor,
          "to" => [@public],
          "object" => object
        })

      {:ok, event} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
      event
    end

    test "a banner sent as an attachment is the cover on the events page, with no media list",
         %{conn: conn} do
      receive_event!("Banner Party", %{"attachment" => [image(@banner)]})

      conn
      |> visit("/events")
      |> wait_async()
      |> assert_has_or_open_browser("[data-id=event_preview]", text: "Banner Party")
      |> assert_has_or_open_browser("[data-id=event_preview] [data-id=event_cover]")
      |> refute_has("[data-id=multimedia_list]")
    end

    test "a banner sent as an attachment is the cover in a feed, with no media list",
         %{conn: conn} do
      receive_event!("Banner Party", %{"attachment" => [image(@banner)]})

      conn
      |> visit("/feed/fediverse")
      |> wait_async()
      |> assert_has_or_open_browser("[data-id=event_preview]", text: "Banner Party")
      |> assert_has_or_open_browser("[data-id=event_preview] [data-id=event_cover]")
      |> refute_has("[data-id=multimedia_list]")
    end

    test "an image and more attachments: the image is the cover, and the rest are not listed",
         %{conn: conn} do
      receive_event!("Poster Party", %{
        "image" => %{"type" => "Image", "url" => @poster, "mediaType" => "image/png"},
        "attachment" => [image(@banner)]
      })

      conn
      |> visit("/events")
      |> wait_async()
      |> assert_has_or_open_browser("[data-id=event_preview] [data-id=event_cover]")
      |> refute_has("[data-id=multimedia_list]")
    end

    test "on the event's own page the image is not the cover but its media attachment, which opens in full",
         %{conn: conn} do
      event = receive_event!("Banner Party", %{"attachment" => [image(@banner)]})

      conn
      |> visit("/discussion/#{event.id}")
      |> wait_async()
      |> assert_has_or_open_browser("[data-id=multimedia_list]")
      |> refute_has("[data-id=event_cover]")
    end

    # Gancio sends an online event's location as a `Link` named with its own URL, which is no title of its own
    test "an online event's link named with its own URL gets our preview" do
      receive_event!("Stream Party", %{
        "attachment" => [
          %{"type" => "Link", "mediaType" => "text/html", "name" => @stream, "href" => @stream}
        ]
      })

      assert {:ok, media} = Media.get_by_url(@stream)
      assert Media.media_label(media) == @stream_title, "label from #{inspect(media.metadata)}"
    end

    test "a link named with text of its own keeps that text, with no preview of ours" do
      url = "https://mocked.local/streams/#{Needle.UID.generate()}"

      receive_event!("Named Stream Party", %{
        "attachment" => [
          %{
            "type" => "Link",
            "mediaType" => "text/html",
            "name" => "Watch the stream",
            "href" => url
          }
        ]
      })

      assert {:ok, media} = Media.get_by_url(url)

      assert Media.media_label(media) == "Watch the stream",
             "label from #{inspect(media.metadata)}"
    end

    test "an event with no image shows the placeholder in a feed, with no media list",
         %{conn: conn} do
      receive_event!("Plain Party", %{})

      conn
      |> visit("/feed/fediverse")
      |> wait_async()
      |> assert_has_or_open_browser("[data-id=event_preview]", text: "Plain Party")
      |> assert_has_or_open_browser("[data-id=event_preview] [data-role=event_placeholder]")
      |> refute_has("[data-id=event_cover]")
      |> refute_has("[data-id=multimedia_list]")
    end
  end
end
