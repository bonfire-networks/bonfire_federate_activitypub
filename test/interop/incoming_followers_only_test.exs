defmodule Bonfire.Federate.ActivityPub.IncomingFollowersOnlyTest do
  @moduledoc """
  Who can read a followers-only post from another server: its author's followers here, and the local users it names, but nobody else.

  The post is the Mastodon capture in `fixtures/mastodon-post-activity.json`, addressed as Mastodon addresses a followers-only post: the author's followers collection in `to`, the people it mentions in `cc`, no Public anywhere. The same capture, with Public moved into `cc`, is Mastodon's unlisted post.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Social.Graph.Follows
  alias ActivityPub.Federator.Transformer

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @author "https://mocked.local/users/karen"
  @author_followers "https://mocked.local/users/karen/followers"
  @other_actor "https://other.local/users/dave"
  @note "https://mocked.local/users/karen/statuses/114800379424129152"

  setup do
    mock(fn
      %{method: :get, url: @author} ->
        json(Simulate.actor_json(@author))

      %{method: :get, url: @other_actor} ->
        json(Simulate.actor_json(@other_actor))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @author)
    {:ok, author} = Bonfire.Me.Users.by_ap_id(@author)

    %{author: author}
  end

  # a local user's follow of a remote author is a request until the author's server accepts it, and only then are they in the author's followers circle
  defp follow_accepted(follower, author, author_ap_id \\ @author) do
    assert {:ok, request} = Follows.follow(follower, author)
    follow_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(request)
    follower_ap_id = ActivityPub.Actor.get_cached!(pointer: follower).ap_id

    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Accept",
               "id" => "#{author_ap_id}#accepts/follows/#{id(follower)}",
               "actor" => author_ap_id,
               "object" => follow_activity.data,
               "to" => [follower_ap_id]
             })

    assert Follows.following?(follower, author)

    assert Bonfire.Boundaries.Circles.is_encircled_by?(
             follower,
             Bonfire.Boundaries.Circles.get_stereotype_circles(author, :followers)
           ),
           "the follower isn't in the author's followers circle"
  end

  defp receive_note(%{to: to, cc: cc}) do
    incoming =
      Path.join(@fixtures, "mastodon-post-activity.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"to" => to, "cc" => cc})
      |> Map.update!("object", &Map.merge(&1, %{"to" => to, "cc" => cc}))

    assert {:ok, _} = Transformer.handle_incoming(incoming)

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @note),
           "the post was not stored at all"

    assert {:ok, post} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true)
    post
  end

  test "a followers-only post from another server can be read by its author's followers here, and not by anyone else",
       %{author: author} do
    follower = fake_user!()
    non_follower = fake_user!()
    follow_accepted(follower, author)

    post = receive_note(%{to: [@author_followers], cc: []})

    # the positive first
    assert Bonfire.Boundaries.can?(follower, [:see, :read], post),
           "a local follower of its author can't read a followers-only post"

    refute Bonfire.Boundaries.can?(non_follower, [:see, :read], post),
           "a local user who doesn't follow its author can read a followers-only post"

    refute Bonfire.Boundaries.can?(:guest, [:see, :read], post),
           "a guest can read a followers-only post"
  end

  test "a followers-only post from another server can be read by a local user it names", %{
    author: author
  } do
    follower = fake_user!()
    named = fake_user!()
    non_follower = fake_user!()
    follow_accepted(follower, author)
    named_ap_id = ActivityPub.Actor.get_cached!(pointer: named).ap_id

    post = receive_note(%{to: [@author_followers], cc: [named_ap_id]})

    assert Bonfire.Boundaries.can?(named, [:see, :read], post),
           "a local user named in a followers-only post can't read it"

    assert Bonfire.Boundaries.can?(follower, [:see, :read], post),
           "a local follower of its author can't read a followers-only post that also names someone"

    refute Bonfire.Boundaries.can?(non_follower, [:see, :read], post)
    refute Bonfire.Boundaries.can?(:guest, [:see, :read], post)
  end

  test "another actor's followers collection in a post's addressing gives that actor's followers here nothing",
       %{author: author} do
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @other_actor)
    {:ok, other} = Bonfire.Me.Users.by_ap_id(@other_actor)
    author_follower = fake_user!()
    other_follower = fake_user!()
    follow_accepted(author_follower, author)

    follow_accepted(other_follower, other, @other_actor)

    post = receive_note(%{to: [@author_followers, "#{@other_actor}/followers"], cc: []})

    # the positive first: the author's own followers collection still maps
    assert Bonfire.Boundaries.can?(author_follower, [:see, :read], post)

    refute Bonfire.Boundaries.can?(other_follower, [:see, :read], post),
           "someone else's followers collection was taken as theirs"
  end

  # Mastodon's "unlisted" (quiet public) post has the author's followers in `to` and Public only in `cc`. Anyone with the link may read it, but it stays out of public timelines, so it reaches followers' home feeds and no public feed.
  describe "an unlisted post from another server" do
    test "a public post is in the public feeds, the control for the unlisted case", %{
      author: author
    } do
      follower = fake_user!()
      follow_accepted(follower, author)

      post = receive_note(%{to: [ActivityPub.Config.public_uri()], cc: [@author_followers]})

      assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, follower)
      assert Bonfire.Social.FeedLoader.feed_contains?(:explore, post, follower)
      assert Bonfire.Social.FeedLoader.feed_contains?(:my, post, follower)
    end

    test "can be read by anyone, reaches followers' home feeds, and stays out of public feeds",
         %{author: author} do
      follower = fake_user!()
      non_follower = fake_user!()
      follow_accepted(follower, author)

      post = receive_note(%{to: [@author_followers], cc: [ActivityPub.Config.public_uri()]})

      assert Bonfire.Boundaries.can?(:guest, [:read], post),
             "an unlisted post should stay readable by link"

      assert Bonfire.Social.FeedLoader.feed_contains?(:my, post, follower),
             "an unlisted post is missing from a follower's home feed"

      refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, non_follower),
             "an unlisted post is in the remote feed"

      refute Bonfire.Social.FeedLoader.feed_contains?(:explore, post, non_follower),
             "an unlisted post is in the explore feed"

      refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post),
             "an unlisted post is in the remote feed for guests"
    end
  end
end
