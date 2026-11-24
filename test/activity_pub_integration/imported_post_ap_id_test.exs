defmodule Bonfire.Federate.ActivityPub.ImportedPostApIdTest do
  @moduledoc """
  A post imported from elsewhere (eg. a Ghost or WordPress article) is published here by a local user, and then remembers its original URL as a canonical URI (`Bonfire.Posts.publish_imported/3`). The fediverse first hears of it through its `Create`, so a later like or reply must point at the same object id that `Create` carried, or other servers can't match them to the post.

  The control is the same post published normally, with no original URL.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Posts
  alias Bonfire.Social.Likes
  alias Bonfire.Federate.ActivityPub.Outgoing

  import Tesla.Mock

  # a real reserved TLD, as `.local` hosts may be handled differently by URL detection (mocked, so nothing leaves the machine)
  @original_url "https://blog.example.com/a-post-from-the-blog/"

  setup do
    mock_global(fn _ -> %Tesla.Env{status: 404, body: ""} end)

    {:ok, author: fake_user!(), other: fake_user!()}
  end

  defp object_id(%{} = ap_activity) do
    case ap_activity.data["object"] do
      %{"id" => id} -> id
      id when is_binary(id) -> id
    end
  end

  defp in_reply_to(%{} = ap_activity) do
    case ap_activity.data["object"] do
      %{"inReplyTo" => id} when is_binary(id) ->
        id

      %{"inReplyTo" => %{"id" => id}} ->
        id

      id when is_binary(id) ->
        {:ok, object} = ActivityPub.Object.get_cached(ap_id: id)
        object.data["inReplyTo"]
    end
  end

  defp like_and_reply(post, other) do
    {:ok, like} = Likes.like(other, post)

    {:ok, reply} =
      Posts.publish(
        current_user: other,
        post_attrs: %{reply_to_id: post.id, post_content: %{html_body: "A reply"}},
        boundary: "public"
      )

    {object_id(Outgoing.ap_activity!(like)), in_reply_to(Outgoing.ap_activity!(reply))}
  end

  test "a like and a reply to a post published here point at the object id its Create carried",
       %{author: author, other: other} do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{name: "A post", html_body: "<p>Typed here</p>"}},
        boundary: "public"
      )

    created_id = object_id(Outgoing.ap_activity!(post))
    {liked_id, replied_to_id} = like_and_reply(post, other)

    assert liked_id == created_id
    assert replied_to_id == created_id
  end

  test "a like and a reply to an imported post point at the object id its Create carried",
       %{author: author, other: other} do
    {:ok, post} =
      Posts.publish_imported(
        author,
        %{name: "A post", html_body: "<p>From the blog</p>", canonical_url: @original_url},
        boundary: "public"
      )

    created_id = object_id(Outgoing.ap_activity!(post))

    # the Create went out with an id on this instance, not the original URL
    assert String.starts_with?(created_id, Bonfire.Common.URIs.base_url())
    refute created_id == @original_url

    # the original URL was saved, so the case under test applies
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@original_url)

    {liked_id, replied_to_id} = like_and_reply(post, other)

    assert liked_id == created_id
    assert replied_to_id == created_id
  end

  # the Update queued by the latest edit
  defp updated_object_id(post, edit) do
    before = MapSet.new(publish_jobs(), & &1.id)
    assert {:ok, _} = edit.()

    assert [%{args: %{"activity_id" => activity_id}}] =
             Enum.reject(publish_jobs(), &MapSet.member?(before, &1.id))

    assert {:ok, update} = ActivityPub.Object.get_cached(id: activity_id)
    assert update.data["type"] == "Update", "the edit is queued as an Update of #{post.id}"
    object_id(update)
  end

  defp publish_jobs,
    do:
      Oban.Testing.all_enqueued(Bonfire.Common.Repo,
        worker: ActivityPub.Federator.Workers.PublisherWorker
      )

  test "an edit of a post published here is an Update of the object id its Create carried",
       %{author: author} do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{name: "A post", html_body: "<p>Typed here</p>"}},
        boundary: "public"
      )

    created_id = object_id(Outgoing.ap_activity!(post))

    assert updated_object_id(post, fn ->
             Bonfire.Social.PostContents.edit(author, post.id, %{html_body: "<p>Edited</p>"})
           end) == created_id
  end

  # as a sync from the site it came from edits it
  test "an edit of an imported post is an Update of the object id its Create carried",
       %{author: author} do
    {:ok, post} =
      Posts.publish_imported(
        author,
        %{name: "A post", html_body: "<p>From the blog</p>", canonical_url: @original_url},
        boundary: "public"
      )

    created_id = object_id(Outgoing.ap_activity!(post))
    assert {:ok, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@original_url)

    assert updated_object_id(post, fn ->
             Bonfire.Social.PostContents.edit(author, post.id, %{
               html_body: "<p>Edited on the blog</p>"
             })
           end) == created_id
  end

  # the activity of `type` queued by `fun`
  defp queued(type, fun) do
    before = MapSet.new(publish_jobs(), & &1.id)
    assert {:ok, _} = fun.()

    assert [activity] =
             publish_jobs()
             |> Enum.reject(&MapSet.member?(before, &1.id))
             |> Enum.map(fn %{args: %{"activity_id" => id}} ->
               {:ok, activity} = ActivityPub.Object.get_cached(id: id)
               activity
             end)
             |> Enum.filter(&(&1.data["type"] == type))

    activity
  end

  # a boost of each post, the one typed here being the control
  test "a boost of a post points at the object id its Create carried, whether typed here or imported",
       %{author: author, other: other} do
    {:ok, typed} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{name: "A post", html_body: "<p>Typed here</p>"}},
        boundary: "public"
      )

    {:ok, imported} =
      Posts.publish_imported(
        author,
        %{name: "A post", html_body: "<p>From the blog</p>", canonical_url: @original_url},
        boundary: "public"
      )

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@original_url)

    for post <- [typed, imported] do
      created_id = object_id(Outgoing.ap_activity!(post))

      assert object_id(queued("Announce", fn -> Bonfire.Social.Boosts.boost(other, post) end)) ==
               created_id
    end
  end

  # a post typed here, the control, and an imported one whose original URL was saved
  defp typed_and_imported(author) do
    {:ok, typed} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{name: "A post", html_body: "<p>Typed here</p>"}},
        boundary: "public"
      )

    {:ok, imported} =
      Posts.publish_imported(
        author,
        %{name: "A post", html_body: "<p>From the blog</p>", canonical_url: @original_url},
        boundary: "public"
      )

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@original_url)

    [typed, imported]
  end

  test "a quote of a post points at the object id its Create carried, whether typed here or imported",
       %{author: author} do
    for post <- typed_and_imported(author) do
      created_id = object_id(Outgoing.ap_activity!(post))

      # its author quotes it, so the quote needs no approval
      {:ok, quoting} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "<p>Quoting it</p>"}},
          quotes: [post],
          boundary: "public"
        )

      %{data: %{"object" => object}} = Outgoing.ap_activity!(quoting)

      object =
        if is_binary(object),
          do: elem(ActivityPub.Object.get_cached(ap_id: object), 1).data,
          else: object

      assert object["quote"] == created_id

      quote_links =
        object["tag"]
        |> List.wrap()
        |> Enum.filter(&(is_map(&1) and &1["rel"] == "https://misskey-hub.net/ns#_misskey_quote"))
        |> Enum.map(& &1["href"])

      assert quote_links == [created_id]
    end
  end

  test "a pin of a post points at the object id its Create carried, whether typed here or imported",
       %{author: author} do
    for post <- typed_and_imported(author) do
      created_id = object_id(Outgoing.ap_activity!(post))

      assert object_id(queued("Add", fn -> Bonfire.Social.Pins.pin(author, post) end)) ==
               created_id
    end
  end

  @follower "https://mocked.local/users/karen"

  # federating on, with a remote follower of `author`, so a Delete has someone to go to and is stored (as in delete_recipients_test.exs)
  defp with_remote_follower(author) do
    Process.put(:federating, true)

    mock_global(fn
      %{method: :get, url: @follower} -> json(Simulate.actor_json(@follower))
      _ -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, author_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(author.id)
    {:ok, follower_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @follower)

    {:ok, follow} =
      ActivityPub.follow(%{actor: follower_actor, object: author_actor, local: false})

    {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow)
  end

  test "a delete of a post is a Delete of the object id its Create carried, whether typed here or imported",
       %{author: author} do
    with_remote_follower(author)

    for post <- typed_and_imported(author) do
      created_id = object_id(Outgoing.ap_activity!(post))
      assert {:ok, _} = Outgoing.push_now!(post)

      # the id to refer to it by in a Delete is the one its Create carried
      assert Bonfire.Federate.ActivityPub.AdapterUtils.federated_object_id(post) == created_id

      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: author)

      # a Delete of the original URL instead would be the wrong id; none at all means it wasn't federated
      by_created_id = ActivityPub.Object.get_activity_for_object_ap_id(created_id, "Delete")
      by_original_url = ActivityPub.Object.get_activity_for_object_ap_id(@original_url, "Delete")

      assert by_created_id || by_original_url, "no Delete stored for #{post.id}"
      assert by_created_id, "the Delete is of #{@original_url}, not #{created_id}"
      assert object_id(by_created_id) == created_id
    end
  end

  # the control is the test above: a post published here gets its Delete pushed
  test "a remote post deleted here by an admin isn't pushed as a Delete of ours", %{
    author: author
  } do
    with_remote_follower(author)
    admin = fake_admin!()

    # a genuinely remote post has to arrive, not be published here on its author's behalf
    ap_id = "#{@follower}/statuses/theirs"

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Create",
               "id" => "#{ap_id}/activity",
               "actor" => @follower,
               "to" => [ActivityPub.Config.public_uri()],
               "object" => %{
                 "id" => ap_id,
                 "type" => "Note",
                 "attributedTo" => @follower,
                 "content" => "<p>theirs, not ours</p>",
                 "to" => [ActivityPub.Config.public_uri()]
               }
             })

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id)

    assert {:ok, _} = Bonfire.Social.Objects.delete(pointer_id, current_user: admin)

    refute ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
           "the post's own instance decides about deleting it; a Delete from us would speak for it"
  end
end
