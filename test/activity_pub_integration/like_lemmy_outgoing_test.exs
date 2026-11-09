defmodule Bonfire.Federate.ActivityPub.LikeLemmyOutgoingTest do
  @moduledoc """
  The `Like` we send for a Lemmy comment has to parse as a Lemmy vote (#2503).

  Lemmy takes a vote in `AnnouncableActivities` (`crates/apub/activities/src/activity_lists.rs`), a serde untagged enum, so a `Like` that fits none of its variants is refused as a whole with HTTP 400 `data did not match any variant of untagged enum AnnouncableActivities`, both by the community's inbox and by the shared inbox. The vote variant is `Vote` (`crates/apub/activities/src/protocol/voting/vote.rs`): `actor`, `object` and `id` are URLs, `type` is `Like` or `Dislike`, `audience` is optional and a single URL. Its own fixture is `crates/apub/apub/assets/lemmy/activities/voting/like_note.json`. Mastodon's `Like` (`mastodon/activities/like_page.json`) is the same with an `object` that is a bare URL and no `audience`.

  The liked object has to go out as its bare id when the Like goes to a group (a Lemmy community among its recipients): an `object` that is a map (the whole liked comment) does not deserialize as a URL, and nothing else about the activity is checked before that. A Like with no group among its recipients keeps the liked object embedded.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Social.Likes

  @community "https://lemmy.local/c/technology"
  @author "https://lemmy.local/u/mayel"
  @post "https://lemmy.local/post/1"
  @comment "https://lemmy.local/comment/26771736"
  @mastodon_author "https://mastodon.local/users/alice"
  @mastodon_status "https://mastodon.local/users/alice/statuses/1"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @fixtures Path.join([__DIR__, "..", "fixtures"])

  setup do
    test_pid = self()

    mock(fn
      %{method: :post, url: url, body: body} ->
        send(test_pid, {:delivered, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: @community} ->
        json(fixture("lemmy", "community_actor.json"))

      %{method: :get, url: @author} ->
        json(Simulate.actor_json(@author, "mayel"))

      %{method: :get, url: @mastodon_author} ->
        json(Simulate.actor_json(@mastodon_author, "alice"))

      # an ordinary Mastodon status: addressed to Public, no group anywhere in its recipients
      %{method: :get, url: @mastodon_status} ->
        json(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => @mastodon_status,
          "type" => "Note",
          "attributedTo" => @mastodon_author,
          "to" => [@public],
          "cc" => ["#{@mastodon_author}/followers"],
          "content" => "<p>a status</p>",
          "published" => "2026-11-09T09:00:00Z"
        })

      # what a Lemmy comment looks like on the wire: a `Note` in the community, addressed to Public with the community in `cc`
      %{method: :get, url: @comment} ->
        json(%{
          "@context" => [
            "https://join-lemmy.org/context.json",
            "https://www.w3.org/ns/activitystreams"
          ],
          "id" => @comment,
          "type" => "Note",
          "attributedTo" => @author,
          "audience" => @community,
          "inReplyTo" => @post,
          "to" => [@public],
          "cc" => [@community, @author],
          "content" => "<p>a comment</p>\n",
          "mediaType" => "text/html",
          "published" => "2026-11-09T09:00:00Z"
        })

      %{method: :get, url: @post} ->
        json(%{
          "@context" => [
            "https://join-lemmy.org/context.json",
            "https://www.w3.org/ns/activitystreams"
          ],
          "id" => @post,
          "type" => "Page",
          "name" => "a post",
          "attributedTo" => @author,
          "audience" => @community,
          "to" => [@community, @public],
          "cc" => [],
          "content" => "<p>a post</p>\n",
          "mediaType" => "text/html",
          "published" => "2026-11-09T08:00:00Z"
        })

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    Process.put(:federating, true)

    liker = fake_user!("lemmy_liker")

    assert {:ok, comment} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(@comment),
           "control: the Lemmy comment was fetched and stored"

    drain_and_flush()

    %{liker: liker, comment: comment}
  end

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp drain_and_flush do
    Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    flush_deliveries()
  end

  defp flush_deliveries do
    receive do
      {:delivered, _, _} -> flush_deliveries()
    after
      0 -> :ok
    end
  end

  # run every queued delivery, and return the `{host, payload}` of each
  defp deliveries do
    Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    collect_deliveries([])
  end

  defp collect_deliveries(acc) do
    receive do
      {:delivered, url, body} ->
        collect_deliveries([{URI.parse(url).host, Jason.decode!(body)} | acc])
    after
      0 -> acc
    end
  end

  # a string with a scheme and host (our own ids are `http://localhost` in tests)
  defp url?(value) when is_binary(value) do
    match?(
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host),
      URI.parse(value)
    )
  end

  defp url?(_), do: false

  # `Vote` in `crates/apub/activities/src/protocol/voting/vote.rs`: serde has no `deny_unknown_fields` there, so extra keys are fine
  defp assert_parses_as_lemmy_vote(vote) do
    for key <- ["actor", "object", "id"] do
      assert url?(vote[key]),
             "Lemmy's Vote reads `#{key}` as a URL, and got: #{inspect(vote[key])}"
    end

    assert vote["type"] in ["Like", "Dislike"]

    assert is_nil(vote["audience"]) or url?(vote["audience"]),
           "Lemmy's Vote reads `audience` as a single URL, and got: #{inspect(vote["audience"])}"
  end

  test "the Like for a Lemmy comment names the comment by its id", %{
    liker: liker,
    comment: comment
  } do
    assert {:ok, like} = Likes.like(liker, comment)
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(like)

    likes = for {host, %{"type" => "Like"} = payload} <- deliveries(), do: {host, payload}

    assert [_ | _] = likes, "control: the Like was delivered to Lemmy"

    for {host, like} <- likes do
      assert like["object"] == @comment,
             "the Like delivered to #{host} carries the liked comment as #{inspect(like["object"], limit: 4)}, where Lemmy's `Vote.object` is a URL, so none of its inboxes can parse it"
    end
  end

  test "the Like for a Lemmy comment parses as a Lemmy vote at every inbox it reaches", %{
    liker: liker,
    comment: comment
  } do
    assert {:ok, like} = Likes.like(liker, comment)
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(like)

    likes = for {_host, %{"type" => "Like"} = payload} <- deliveries(), do: payload

    assert [_ | _] = likes, "control: the Like was delivered to Lemmy"
    Enum.each(likes, &assert_parses_as_lemmy_vote/1)
  end

  # the bare id is for a Like that goes to a group: anyone else keeps getting the liked post embedded
  test "the Like for a post with no group among its recipients keeps the liked post embedded", %{
    liker: liker
  } do
    assert {:ok, status} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(
               @mastodon_status
             )

    drain_and_flush()

    assert {:ok, like} = Likes.like(liker, status)
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(like)

    likes = for {host, %{"type" => "Like"} = payload} <- deliveries(), do: {host, payload}

    assert [_ | _] = likes, "control: the Like was delivered to Mastodon"

    for {host, like} <- likes do
      assert %{"id" => @mastodon_status} = like["object"],
             "the Like delivered to #{host} carries the liked post as #{inspect(like["object"], limit: 4)}, where only a Like that goes to a group is cut down to its id"
    end
  end

  # `UndoVote` carries the `Vote` in `object`, so the same rule holds one level down
  test "taking the Like back sends an Undo whose Like parses as a Lemmy vote", %{
    liker: liker,
    comment: comment
  } do
    assert {:ok, like} = Likes.like(liker, comment)
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(like)
    drain_and_flush()

    assert {:ok, _} = Likes.unlike(liker, comment)

    undos = for {_host, %{"type" => "Undo"} = payload} <- deliveries(), do: payload

    assert [_ | _] = undos, "control: the Undo was delivered to Lemmy"

    for undo <- undos do
      assert %{"type" => "Like"} = undo["object"], "the Undo names the Like it takes back"
      assert_parses_as_lemmy_vote(undo["object"])
    end
  end
end
