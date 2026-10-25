defmodule Bonfire.Federate.ActivityPub.OutOfOrderThreadTest do
  @moduledoc """
  Posts of a thread can reach us in any order: a reply can arrive before the post it answers, for example when its server was down or the thread is deeper than we fetch. Such a reply is kept as a thread of its own until its parent arrives. Then it, and the replies under it, move under the parent, with the `reply_to_id`, `thread_id`, `path` and reply counts they would have had if the posts had arrived in order.

  A remote post that has not "arrived" yet answers 404, so fetching it while its reply is received fails, as it does when its server is down.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Tesla.Mock
  import Ecto.Query

  alias Bonfire.Posts
  alias Bonfire.Data.Social.Replied
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Incoming
  alias Bonfire.Federate.ActivityPub.Simulate
  alias ActivityPub.Federator.Transformer

  @replier "https://replier.local/users/rita"
  @other_replier "https://other.local/users/olive"
  @author "https://author.local/users/ann"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    actors =
      Map.new([{@replier, "rita"}, {@other_replier, "olive"}, {@author, "ann"}], fn {id, name} ->
        {id, Simulate.actor_json(id, name)}
      end)

    # the notes that a remote server serves, by AP id, which a test adds to once the note has "arrived"
    {:ok, served} = start_supervised({Agent, fn -> %{} end})

    mock_global(fn
      %{method: :get, url: url} when is_map_key(actors, url) ->
        json(actors[url])

      %{method: :get, url: url} ->
        case Agent.get(served, &Map.get(&1, url)) do
          nil -> %Tesla.Env{status: 404, body: ""}
          note -> json(note)
        end

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    %{served: served}
  end

  defp note(name, in_reply_to \\ nil, actor \\ @replier) do
    %{
      "id" => "#{actor}/notes/#{name}-#{System.unique_integer([:positive])}",
      "type" => "Note",
      "attributedTo" => actor,
      "content" => "<p>#{name}</p>",
      "inReplyTo" => in_reply_to && in_reply_to["id"],
      "to" => [@public],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # delivered to our inbox, wrapped in its author's Create
  defp deliver(note) do
    assert {:ok, activity} =
             Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "id" => note["id"] <> "/activity",
               "type" => "Create",
               "actor" => note["attributedTo"],
               "to" => note["to"],
               "object" => note
             })

    assert {:ok, %{id: _}} = Incoming.receive_activity(activity)
    note
  end

  defp local_id(%{"id" => ap_id}) do
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id)
    refute is_nil(pointer_id), "#{ap_id} should be linked to a local object"
    pointer_id
  end

  defp local_id(%{id: id}), do: id

  defp replied(object), do: repo().get!(Replied, local_id(object))

  defp assert_threaded(object, under, path) do
    replied = replied(object)
    path_ids = Enum.map(path, &local_id/1)

    assert replied.reply_to_id == local_id(under),
           "#{inspect(object["content"])} should be a reply to its parent"

    assert replied.thread_id == List.first(path_ids), "and in the thread of its opener"
    assert replied.path == path_ids, "with the path of its ancestors, opener first"
  end

  # unused since a reply whose parent we couldn't fetch waits under a placeholder (`assert_waiting/2`) rather than starting a thread of its own
  # defp assert_orphan(object) do
  #   replied = replied(object)
  #   assert replied.reply_to_id == nil
  #   assert replied.thread_id == local_id(object)
  #   assert replied.path == []
  # end

  # a reply whose parent we don't hold yet, threaded under the placeholder for it
  defp assert_waiting(object, parent) do
    assert placeholder_id = placeholder_id(parent), "a placeholder stands in for the parent"
    assert replied(object).reply_to_id == placeholder_id
  end

  defp assert_counts(object, direct, nested) do
    replied = replied(object)
    assert {replied.direct_replies_count, replied.nested_replies_count} == {direct, nested}
  end

  test "an opener that arrives after its replies gathers them into its thread" do
    opener = note("opener", nil, @author)
    a = deliver(note("a", opener))
    b = deliver(note("b", a))

    assert_waiting(a, opener)

    deliver(opener)

    assert_threaded(a, opener, [opener])
    assert_threaded(b, a, [opener, a])
    assert_counts(opener, 1, 1)
    assert_counts(a, 1, 0)
  end

  test "a reply that arrives after its own replies takes them into the thread it joins" do
    alice = fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: alice,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "<p>opener</p>"}}
      )

    {:ok, %{data: opener}} = ActivityPub.Object.get_cached(pointer: post.id)

    b = note("b", opener)
    c = deliver(note("c", b))

    assert_waiting(c, b)

    deliver(b)

    assert_threaded(b, post, [post])
    assert_threaded(c, b, [post, b])
    assert_counts(post, 1, 1)
    assert_counts(b, 1, 0)
  end

  test "replies in several branches, with two gaps, all end up in the opener's thread" do
    opener = note("opener", nil, @author)
    x = note("x", opener, @other_replier)

    a = deliver(note("a", opener))
    b = deliver(note("b", opener, @other_replier))
    a2 = deliver(note("a2", x))

    deliver(x)

    assert replied(a2).reply_to_id == local_id(x), "x took its placeholder's place"
    assert_waiting(x, opener)
    assert_waiting(a, opener)

    deliver(opener)

    assert_threaded(a, opener, [opener])
    assert_threaded(b, opener, [opener])
    assert_threaded(x, opener, [opener])
    assert_threaded(a2, x, [opener, x])
    assert_counts(opener, 3, 1)
    assert_counts(x, 1, 0)
  end

  test "an opener we fetch, rather than receive, gathers its replies too", %{served: served} do
    opener = note("opener", nil, @author)
    a = deliver(note("a", opener))

    assert_waiting(a, opener)

    Agent.update(served, &Map.put(&1, opener["id"], opener))

    assert {:ok, _} = ActivityPub.Federator.Fetcher.fetch_object_from_id(opener["id"])

    assert_threaded(a, opener, [opener])
    assert_counts(opener, 1, 0)
  end

  # A reply refused when it arrives after its parent (`Threads.find_reply_to/2`), but here it arrives first and waits under a placeholder, which takes no boundary check: who may reply to a remote post is its author's server's call. So it stays in the thread once the parent arrives
  test "a reply that waited under a placeholder stays in the thread, even one its author may not reply to" do
    # addressed only to one of our users, so the replier can't see it, nor reply to it
    recipient = Bonfire.Me.Characters.character_url(fake_user!())
    private = &Map.put(&1, "to", [recipient])

    opener = private.(note("opener", nil, @author))
    a = deliver(note("a", opener))
    # the author may always reply to their own post
    b = deliver(note("b", opener, @author))

    deliver(opener)

    # the check that refuses this reply when it arrives after the opener (`Threads.find_reply_to/2`)
    {:ok, replier} = AdapterUtils.get_or_fetch_character_by_ap_id(@replier)

    refute Bonfire.Boundaries.can?(replier, :reply, local_id(opener)),
           "control: the replier would be refused, had they replied after the opener arrived"

    assert_threaded(b, opener, [opener])
    assert_threaded(a, opener, [opener])
    assert_counts(opener, 2, 0)
  end

  # Whichever way a reply reaches us, the post it answers is fetched with it, so it arrives in its thread. Each delivery goes through the inbox worker that takes it in production, which is what decides whether the parent is fetched right away (`Fetcher.maybe_fetch/2`)
  describe "the post a reply answers is fetched with it, when the reply" do
    setup %{served: served} do
      opener = note("opener", nil, @author)
      reply = note("reply", opener)
      serve = fn note -> Agent.update(served, &Map.put(&1, note["id"], note)) end
      serve.(opener)
      %{opener: opener, reply: reply, serve: serve}
    end

    test "is delivered to our inbox", %{opener: opener, reply: reply} do
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(reply))

      assert_threaded(reply, opener, [opener])
    end

    test "is delivered to one of our users it mentions", %{opener: opener, reply: reply} do
      us = Bonfire.Me.Characters.character_url(fake_user!())
      reply = Map.put(reply, "cc", [us])

      receive_in(ActivityPub.Federator.Workers.ReceiverMentionsWorker, create(reply))

      assert_threaded(reply, opener, [opener])
    end

    test "is boosted", %{opener: opener, reply: reply, serve: serve} do
      serve.(reply)

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{@other_replier}/boosts/#{System.unique_integer([:positive])}",
        "type" => "Announce",
        "actor" => @other_replier,
        "to" => [@public],
        "object" => reply["id"]
      })

      assert_threaded(reply, opener, [opener])
    end

    test "is delivered to our inbox, and answers a reply: both posts above it are fetched", %{
      opener: opener,
      serve: serve
    } do
      middle = note("middle", opener, @other_replier)
      serve.(middle)
      reply = note("reply to the middle", middle)

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(reply))

      assert_threaded(middle, opener, [opener])
      assert_threaded(reply, middle, [opener, middle])
    end

    test "is boosted, and answers a reply: both posts above it are fetched", %{
      opener: opener,
      serve: serve
    } do
      middle = note("middle", opener, @other_replier)
      reply = note("reply to the middle", middle)
      serve.(middle)
      serve.(reply)

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{@other_replier}/boosts/#{System.unique_integer([:positive])}",
        "type" => "Announce",
        "actor" => @other_replier,
        "to" => [@public],
        "object" => reply["id"]
      })

      assert_threaded(middle, opener, [opener])
      assert_threaded(reply, middle, [opener, middle])
    end

    test "is quoted", %{opener: opener, reply: reply, serve: serve} do
      serve.(reply)
      quoting = note("quoting", nil, @other_replier) |> Map.put("quote", reply["id"])

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(quoting))

      assert_threaded(reply, opener, [opener])
    end
  end

  # A reply deeper than the `inReplyTo` climb reaches (5 posts up, `federation_incoming_max_items`): its opener comes from the thread's `context`, a collection of its posts with the opener first (FEP-f228), captured from each server. The posts between the climb's top and the opener aren't fetched, but join the thread whenever they arrive
  describe "a reply deeper than the climb reaches" do
    for {shape, fixture} <- [
          {"Mastodon", "mastodon"},
          {"NodeBB", "nodebb"},
          {"PieFed", "piefed"}
        ] do
      @fixture fixture
      test "still brings in the opener, from a #{shape} context", %{served: served} do
        [opener, r1 | _] = chain = chain(served, context_collection(@fixture))

        receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(List.last(chain)))

        refute held?(r1),
               "control: the climb stops below r1, so only the context can bring the opener"

        assert held?(opener)
      end
    end

    test "still brings in the opener, from a Lemmy context, which is the opener itself", %{
      served: served
    } do
      [opener, r1 | _] = chain = chain(served, :opener)

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(List.last(chain)))

      refute held?(r1)
      assert held?(opener)
    end

    test "still brings in the opener when the reply isn't delivered to our inbox", %{
      served: served
    } do
      [opener, r1 | _] = chain = chain(served, context_collection("mastodon"))

      deliver(List.last(chain))
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      refute held?(r1)
      assert held?(opener)
    end

    test "is one thread: the placeholder for the post the climb didn't reach sits under the opener",
         %{served: served} do
      [opener, r1, r2 | _] = chain = chain(served, context_collection("mastodon"))

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(List.last(chain)))

      assert_waiting(r2, r1)
      placeholder_id = placeholder_id(r1)
      opener_id = local_id(opener)

      assert {replied(r2).thread_id, replied(r2).path} == {opener_id, [opener_id, placeholder_id]},
             "under the placeholder, in the opener's thread"

      assert replied(List.last(chain)).thread_id == opener_id
    end

    test "and a post in between pushed to us later joins them up", %{served: served} do
      [opener, r1 | _] = chain = chain(served, context_collection("mastodon"))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(List.last(chain)))

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(r1))

      assert_chain_threaded(chain)
      assert held?(opener)
    end

    test "and a post in between fetched later joins them up", %{served: served} do
      [_opener, r1 | _] = chain = chain(served, context_collection("mastodon"))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(List.last(chain)))

      assert {:ok, _} = ActivityPub.Federator.Fetcher.fetch_object_from_id(r1["id"])

      assert_chain_threaded(chain)
    end
  end

  # A post we couldn't fetch stands in the thread as a placeholder: a plain pointer, soft-deleted so nothing lists it, found by its URL (`Peered`). The replies under it point at its id, and when it arrives it is created under that id, so they never move
  describe "a placeholder" do
    test "stands in for a parent we couldn't fetch, with the reply under it" do
      parent = note("parent", nil, @author)
      reply = note("reply", parent)

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(reply))

      placeholder_id = placeholder_id(parent)
      assert placeholder_id, "a placeholder is found by the parent's URL"

      assert %{deleted_at: %DateTime{}} = repo().get!(Needle.Pointer, placeholder_id),
             "soft-deleted, so nothing lists it"

      replied = replied(reply)

      assert {replied.reply_to_id, replied.thread_id, replied.path} ==
               {placeholder_id, placeholder_id, [placeholder_id]}
    end

    test "is filled by the parent when it arrives, and the reply under it doesn't move", %{
      served: served
    } do
      parent = note("parent", nil, @author)
      reply = note("reply", parent)
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(reply))
      placeholder_id = placeholder_id(parent)

      Agent.update(served, &Map.put(&1, parent["id"], parent))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(parent))

      assert local_id(parent) == placeholder_id, "the parent takes the placeholder's id"

      assert {:ok, %Bonfire.Data.Social.Post{}} =
               Bonfire.Common.Needles.get(placeholder_id, skip_boundary_check: true)

      assert_threaded(reply, parent, [parent])
      assert_counts(parent, 1, 0)
    end

    test "is filled by a post that answers one we hold, and what's under it follows into that thread",
         %{served: served} do
      opener = deliver(note("opener", nil, @author))
      parent = note("parent", opener)
      reply = note("reply", parent, @other_replier)
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(reply))

      Agent.update(served, &Map.put(&1, parent["id"], parent))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(parent))

      assert_threaded(parent, opener, [opener])
      assert_threaded(reply, parent, [opener, parent])
      assert_counts(opener, 1, 1)
      assert_counts(parent, 1, 0)
    end
  end

  describe "a placeholder under the opener" do
    # all we know of a post we couldn't fetch is its thread, so it waits right under the opener, and moves to where it really is once it arrives
    test "is filled by a deeper reply, and what's under it follows it down", %{served: served} do
      context_url = "#{@author}/contexts/#{System.unique_integer([:positive])}"
      in_context = &Map.put(&1, "context", context_url)

      opener = in_context.(note("opener", nil, @author))
      x = in_context.(note("x", opener, @other_replier))
      p = in_context.(note("p", x, @author))
      r = in_context.(note("r", p))

      Agent.update(served, fn docs ->
        docs
        |> Map.put(opener["id"], opener)
        |> Map.put(context_url, with_first_item(context_collection("mastodon"), opener["id"]))
      end)

      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(opener))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(x))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(r))

      opener_id = local_id(opener)
      placeholder_id = placeholder_id(p)
      assert_waiting(r, p)

      assert replied(r).path == [opener_id, placeholder_id],
             "control: waiting under the placeholder, which waits under the opener"

      Agent.update(served, &Map.put(&1, p["id"], p))
      receive_in(ActivityPub.Federator.Workers.ReceiverWorker, create(p))

      assert local_id(p) == placeholder_id
      assert_threaded(p, x, [opener, x])
      assert_threaded(r, p, [opener, x, p])
      assert_counts(opener, 1, 2)
      assert_counts(x, 1, 1)
      assert_counts(p, 1, 0)
    end
  end

  defp placeholder_id(%{"id" => ap_id}) do
    from(p in Bonfire.Data.ActivityPub.Peered, where: p.canonical_uri == ^ap_id, select: p.id)
    |> repo().one()
  end

  @deep 7

  # O ← r1 ← … ← r7, each with the thread's `context`: all served but the last, which is what arrives. `context` is a collection (opener first) served at its own URL, or `:opener` for Lemmy's, which is the opener itself
  defp chain(served, context) do
    serve = fn %{"id" => id} = doc -> Agent.update(served, &Map.put(&1, id, doc)) end
    opener_id = "#{@author}/notes/opener-#{System.unique_integer([:positive])}"

    context_url =
      case context do
        :opener -> opener_id
        _ -> "#{@author}/contexts/#{System.unique_integer([:positive])}"
      end

    opener =
      note("opener", nil, @author) |> Map.merge(%{"id" => opener_id, "context" => context_url})

    chain =
      Enum.reduce(1..@deep, [opener], fn n, [parent | _] = acc ->
        [
          note("r#{n}", parent, if(rem(n, 2) == 0, do: @author, else: @replier))
          |> Map.put("context", context_url)
          | acc
        ]
      end)
      |> Enum.reverse()

    Enum.each(Enum.drop(chain, -1), serve)

    if is_map(context) do
      Agent.update(served, &Map.put(&1, context_url, with_first_item(context, opener_id)))
    end

    chain
  end

  defp context_collection(dir),
    do:
      Path.join([__DIR__, "..", "fixtures", dir, "context_collection.json"])
      |> File.read!()
      |> Jason.decode!()

  # the captured collection, its first item (the opener) pointed at this test's
  defp with_first_item(%{"first" => %{"items" => [_ | rest]}} = collection, id),
    do: put_in(collection, ["first", "items"], [id | rest])

  defp with_first_item(%{"orderedItems" => [_ | rest]} = collection, id),
    do: Map.put(collection, "orderedItems", [id | rest])

  defp held?(%{"id" => ap_id}) do
    match?(
      {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id),
      ActivityPub.Object.get_cached(ap_id: ap_id)
    )
  end

  defp assert_chain_threaded([opener | replies]) do
    Enum.reduce(replies, [opener], fn reply, [parent | _] = ancestors ->
      assert_threaded(reply, parent, Enum.reverse(ancestors))
      [reply | ancestors]
    end)
  end

  defp create(note) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => note["id"] <> "/activity",
      "type" => "Create",
      "actor" => note["attributedTo"],
      "to" => note["to"],
      "cc" => note["cc"] || [],
      "object" => note
    }
  end

  # as the inbox controller queues it, after checking the HTTP signature
  defp receive_in(worker, activity) do
    perform_job(worker, %{
      "op" => "incoming_ap_doc",
      "params" => activity,
      "signed_by" => activity["actor"],
      "repo" => ActivityPub.Utils.repo()
    })
  end
end
