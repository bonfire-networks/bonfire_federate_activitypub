defmodule Bonfire.Federate.ActivityPub.CommentsEnabledIncomingTest do
  @moduledoc """
  An incoming object's `commentsEnabled` (PeerTube, Pixelfed, Mobilizon, …): `false` closes its thread here (`Blocks.lock/2`), and an `Update` saying `true` reopens it (`Threads.ap_receive_comments_enabled/4`).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation
  import Tesla.Mock

  alias Bonfire.Boundaries

  @actor "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @group "https://groups.local/c/relayer"

  setup_all do
    mock_global(fn
      %{method: :get, url: @actor} ->
        json(Simulate.actor_json(@actor))

      %{method: :get, url: @group} ->
        json(Simulate.actor_json(@group, "relayer", %{"type" => "Group"}))

      # the origin serves these notes open, whatever a relayed copy says
      %{method: :get, url: "https://mocked.local/users/karen/notes/open-" <> _ = url} ->
        json(note(url, true))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp note(id, comments_enabled) do
    %{
      "type" => "Note",
      "id" => id,
      "attributedTo" => @actor,
      "content" => "a note",
      "to" => [@public],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "commentsEnabled" => comments_enabled
    }
  end

  defp receive_incoming(type, object) do
    {:ok, data} =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => type,
        "id" => "#{object["id"]}/#{String.downcase(type)}/#{Needle.UID.generate()}",
        "actor" => @actor,
        "to" => [@public],
        "object" => object
      })

    {:ok, received} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    received
  end

  test "a note arriving with comments disabled is locked, and an Update enabling them reopens it" do
    id = "#{@actor}/notes/#{Needle.UID.generate()}"
    someone = fake_user!()

    post = receive_incoming("Create", note(id, false))
    refute Boundaries.can?(someone, :reply, post), "closed, as it arrived"

    receive_incoming("Update", note(id, true))
    assert Boundaries.can?(someone, :reply, post), "reopened by the update"
  end

  # A moderator closing a thread is moderating it: the author can reopen a thread they closed themselves, but not one a moderator closed, whether by editing it (`commentsEnabled: true`) or by unlocking it here. An instance admin stands in for the moderator
  describe "a thread a moderator closed" do
    test "is not reopened by its remote author's Update", %{} do
      id = "#{@actor}/notes/#{Needle.UID.generate()}"
      someone = fake_user!()
      admin = fake_admin!()

      post = receive_incoming("Create", note(id, true))
      assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: admin)
      refute Boundaries.can?(someone, :reply, post), "control: closed by the moderator"

      receive_incoming("Update", note(id, true))

      refute Boundaries.can?(someone, :reply, post),
             "its author's edit reopened a moderator's lock"
    end

    test "is not reopened by its local author, who can reopen one they closed themselves" do
      author = fake_user!()
      someone = fake_user!()
      admin = fake_admin!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "<p>a thread</p>"}},
          boundary: "public"
        )

      assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: admin)

      assert Bonfire.Social.Moderations.recorded_by(post, :lock) == admin.id,
             "control: the lock's record names the moderator"

      Bonfire.Boundaries.Blocks.unlock(post, current_user: author)
      refute Boundaries.can?(someone, :reply, post), "its author reopened a moderator's lock"

      # control: the moderator can, and the author can reopen their own
      assert {:ok, _} = Bonfire.Boundaries.Blocks.unlock(post, current_user: admin)
      assert Boundaries.can?(someone, :reply, post)

      assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: author)
      assert {:ok, _} = Bonfire.Boundaries.Blocks.unlock(post, current_user: author)
      assert Boundaries.can?(someone, :reply, post), "control: the author reopens their own lock"
    end
  end

  # Under the `:trust` relay mode a relayed activity is taken as it comes, which FEP-1b12 means for the post's own group. A relay by anyone else, of a post we hold, is checked against the origin, or any server could close, reopen or rewrite someone else's post by wrapping an `Update` of it in an `Announce`
  describe "a relayed copy nobody vouched for" do
    setup do
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @group)
      %{id: "#{@actor}/notes/open-#{Needle.UID.generate()}", someone: fake_user!()}
    end

    defp update_of(object) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Update",
        "id" => "#{object["id"]}/update/#{Needle.UID.generate()}",
        "actor" => @actor,
        "to" => [@public],
        "object" => object
      }
    end

    defp relayed_by_group(inner) do
      ActivityPub.Federator.Transformer.handle_incoming(
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "type" => "Announce",
          "id" => "#{@group}/activities/announce/#{Needle.UID.generate()}",
          "actor" => @group,
          "to" => [@public],
          "object" => inner
        },
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: @group
      )
    end

    test "an Update relayed by a group the post is not in doesn't close a thread its origin serves open",
         %{id: id, someone: someone} do
      post = receive_incoming("Create", note(id, true))
      assert Boundaries.can?(someone, :reply, post), "control: open to begin with"

      relayed_by_group(update_of(note(id, false)))

      assert Boundaries.can?(someone, :reply, post), "a stranger's relay closed the thread"
    end

    test "control: the author's own Update closes it", %{id: id, someone: someone} do
      post = receive_incoming("Create", note(id, true))

      ActivityPub.Federator.Transformer.handle_incoming(update_of(note(id, false)),
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: @actor
      )

      refute Boundaries.can?(someone, :reply, post)
    end

    test "control: the post's own group relaying it is believed", %{id: id, someone: someone} do
      post = receive_incoming("Create", note(id, true) |> Map.put("audience", @group))
      assert Boundaries.can?(someone, :reply, post), "control: open to begin with"

      relayed_by_group(update_of(note(id, false) |> Map.put("audience", @group)))

      refute Boundaries.can?(someone, :reply, post)
    end
  end
end
