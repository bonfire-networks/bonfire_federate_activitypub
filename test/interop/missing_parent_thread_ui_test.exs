defmodule Bonfire.Federate.ActivityPub.MissingParentThreadUITest do
  @moduledoc """
  How a thread looks when a post in it could not be fetched: the opener O is fetched, its reply r1 is not (its server answers 404), and r2, which answers r1, arrives with its own reply r3.

  r2 waits under a placeholder for r1, which the thread's `context` (a collection with O first, as Mastodon serves it) puts under O. So the opener's page shows one thread: O, then a "not fetched yet" slot for r1 with a way to fetch it, then r2 and r3.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo
  @moduletag :federation

  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub.Simulate

  @author "https://author.local/users/ann"
  @replier "https://replier.local/users/rita"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @context "https://author.local/contexts/1"

  setup do
    actors = %{
      @author => Simulate.actor_json(@author, "ann"),
      @replier => Simulate.actor_json(@replier, "rita")
    }

    opener = note("The opening post", nil, @author)
    middle = note("The reply we could not fetch", opener, @author)

    collection =
      Path.join([__DIR__, "..", "fixtures", "mastodon", "context_collection.json"])
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("id", @context)
      |> put_in(["first", "items"], [opener["id"], middle["id"]])

    # the opener and the thread's context are served, the reply to the opener is not (until a test serves it)
    {:ok, served} =
      start_supervised({Agent, fn -> %{opener["id"] => opener, @context => collection} end})

    mock_global(fn
      %{method: :get, url: url} when is_map_key(actors, url) ->
        json(actors[url])

      %{method: :get, url: url} ->
        case Agent.get(served, &Map.get(&1, url)) do
          nil -> %Tesla.Env{status: 404, body: ""}
          doc -> json(doc)
        end

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    orphan = note("A reply to the post we could not fetch", middle)
    deliver(orphan)
    deliver(note("A reply to that reply", orphan))

    account = fake_account!()
    me = fake_user!(account)

    {:ok,
     conn: conn(user: me, account: account),
     opener: opener,
     middle: middle,
     orphan: orphan,
     served: served}
  end

  test "the opener's thread shows a slot for the post we couldn't fetch, with the replies under it",
       %{conn: conn, opener: opener, middle: middle, served: served} do
    session =
      conn
      |> visit(discussion_path(opener))
      |> wait_async()
      # |> open_browser()
      |> assert_has("[data-id=object_body]", text: "The opening post")
      |> assert_has("[data-role=comment-not-fetched]")
      |> assert_has("[data-id=object_body]", text: "A reply to the post we could not fetch")
      |> assert_has("[data-id=object_body]", text: "A reply to that reply")
      # its server answers now
      |> tap(fn _ -> Agent.update(served, &Map.put(&1, middle["id"], middle)) end)
      |> click_button("[data-role=fetch-not-fetched]", "Try loading it")
      |> assert_has("*", text: "Syncing with remote server")

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    # shown in the open thread as it arrives, in its slot's place
    session
    |> assert_has("[data-id=object_body]", text: "The reply we could not fetch", timeout: 3000)
    # |> open_browser()
    |> refute_has("[data-role=comment-not-fetched]", timeout: 3000)
    |> assert_has("[data-id=object_body]", text: "A reply to the post we could not fetch")
    |> assert_has("[data-id=object_body]", text: "A reply to that reply")
  end

  # Two posts in a row we don't hold, x and the p that answers it, above the r we received. All we know of p is its thread, so its slot shows right under the opener. Loading p tells us it answers x, which still can't be fetched, so x gets a slot of its own, with p under it. Loading x completes the thread
  test "two levels we don't hold come in one at a time, each going where it really is",
       %{conn: conn, served: served} do
    context = "https://author.local/contexts/2"
    opener = note("Nested: the opening post", nil, @author, context)
    x = note("Nested: the first reply we could not fetch", opener, @replier, context)
    p = note("Nested: the second reply we could not fetch", x, @author, context)
    r = note("Nested: the reply we received", p, @replier, context)

    collection =
      Path.join([__DIR__, "..", "fixtures", "mastodon", "context_collection.json"])
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("id", context)
      |> put_in(["first", "items"], [opener["id"], x["id"], p["id"]])

    Agent.update(served, &(&1 |> Map.put(opener["id"], opener) |> Map.put(context, collection)))

    deliver(r)

    session =
      conn
      |> visit(discussion_path(opener))
      |> wait_async()
      # |> open_browser()
      |> assert_has("[data-id=object_body]", text: "Nested: the opening post")
      |> assert_has("[data-role=comment-not-fetched]", count: 1)
      |> assert_has("[data-id=object_body]", text: "Nested: the reply we received")
      # p's server answers now, x's still doesn't
      |> tap(fn _ -> Agent.update(served, &Map.put(&1, p["id"], p)) end)
      |> click_button("[data-role=fetch-not-fetched]", "Try loading it")

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    # the open thread shows p, now under a slot for x, which it answers, with r still under p
    session
    |> assert_has("[data-id=object_body]",
      text: "Nested: the second reply we could not fetch",
      timeout: 3000
    )
    # |> open_browser()
    |> assert_has("[data-role=comment-not-fetched]", count: 1)
    |> assert_has("[data-id=object_body]", text: "Nested: the reply we received")
    # x's server answers now
    |> tap(fn _ -> Agent.update(served, &Map.put(&1, x["id"], x)) end)
    |> click_button("[data-role=fetch-not-fetched]", "Try loading it")

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    # and then x, in its slot's place: the thread is complete
    session
    |> assert_has("[data-id=object_body]",
      text: "Nested: the first reply we could not fetch",
      timeout: 3000
    )
    # |> open_browser()
    |> refute_has("[data-role=comment-not-fetched]", timeout: 3000)
    |> assert_has("[data-id=object_body]", text: "Nested: the second reply we could not fetch")
    |> assert_has("[data-id=object_body]", text: "Nested: the reply we received")
  end

  defp note(content, in_reply_to, actor \\ @replier, context \\ @context) do
    %{
      "id" => "#{actor}/notes/#{System.unique_integer([:positive])}",
      "type" => "Note",
      "attributedTo" => actor,
      "content" => "<p>#{content}</p>",
      "inReplyTo" => in_reply_to && in_reply_to["id"],
      "context" => context,
      "to" => [@public],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # delivered to our inbox, as the inbox controller queues it after checking the HTTP signature
  defp deliver(note) do
    perform_job(ActivityPub.Federator.Workers.ReceiverWorker, %{
      "op" => "incoming_ap_doc",
      "params" => %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => note["id"] <> "/activity",
        "type" => "Create",
        "actor" => note["attributedTo"],
        "to" => [@public],
        "object" => note
      },
      "signed_by" => note["attributedTo"],
      "repo" => ActivityPub.Utils.repo()
    })

    note
  end

  defp discussion_path(%{"id" => ap_id}) do
    {:ok, %{pointer_id: id}} = ActivityPub.Object.get_cached(ap_id: ap_id)
    "/discussion/#{id}"
  end
end
