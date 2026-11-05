defmodule Bonfire.Federate.ActivityPub.GroupIncomingReplyAudienceTest do
  @moduledoc """
  Who can see a comment from a remote instance on a post in one of OUR groups. Its audience is its own addressing, never wider than the post it replies to: a followers-only comment on a public post stays followers-only, a public comment on a members-only post stays members-only, and a public comment on a public post is public.

  The comments are built from the Lemmy capture in `fixtures/lemmy/create_note_reply_in_group.json` (Public in `to`, the group and the parent's author in `cc`), with `to`/`cc` changed for the followers-only case, as a Mastodon user would address it: their followers collection in `to`, the group and the parent's author in `cc`, no Public anywhere.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @author "https://lemmy.local/u/mayel"
  @author_followers "https://lemmy.local/u/mayel/followers"
  @comment "https://lemmy.local/comment/27985030"
  @group_placeholder "https://bonfire.local/pub/group/GROUP"

  setup do
    mock(fn
      %{method: :get, url: @author} ->
        json(APSimulate.actor_json(@author, "mayel"))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    member = fake_user!()
    outsider = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, _} =
      Bonfire.Classify.Categories.add_member(creator, group, member.id, skip_boundary_check: true)

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    %{creator: creator, member: member, outsider: outsider, group: group, group_ap_id: actor.ap_id}
  end

  defp publish_parent(creator, group, boundary) do
    assert {:ok, parent} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>a post to reply to</p>"}},
               boundary: boundary,
               publish_in: uid(group)
             )

    parent
  end

  # the reply fixture, aimed at `parent` in `group`, with `to`/`cc` on both the activity and the object replaced when given
  defp incoming_reply(parent, creator, group_ap_id, addressing \\ nil) do
    parent_ap_id =
      case ActivityPub.Object.get_cached(pointer: parent) do
        {:ok, %{data: %{"id" => ap_id}}} -> ap_id
        _ -> Bonfire.Common.URIs.canonical_url(parent)
      end

    creator_ap_id = ActivityPub.Actor.get_cached!(pointer: creator).ap_id

    incoming =
      Path.join([@fixtures, "lemmy", "create_note_reply_in_group.json"])
      |> File.read!()
      |> String.replace(@group_placeholder, group_ap_id)
      |> String.replace("https://bonfire.local/pub/objects/PARENT", parent_ap_id)
      |> String.replace("https://bonfire.local/pub/person/AUTHOR", creator_ap_id)
      |> Jason.decode!()

    case addressing do
      nil ->
        incoming

      %{to: to, cc: cc} ->
        incoming
        |> Map.merge(%{"to" => to, "cc" => cc})
        |> Map.update!("object", &Map.merge(&1, %{"to" => to, "cc" => cc}))
    end
  end

  defp receive_reply(incoming) do
    assert {:ok, _} = Transformer.handle_incoming(incoming)

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @comment),
           "the comment was not stored at all"

    assert {:ok, reply} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true)
    reply
  end

  # only members may reply to a members-only post, so the comment's author joins first, with the `Join` their server sends (the group's membership is open)
  defp join_group(group, group_ap_id) do
    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Join",
               "id" => "#{@author}/join/1",
               "actor" => @author,
               "object" => group_ap_id,
               "to" => [group_ap_id]
             })

    assert Bonfire.Classify.Categories.member?(remote_author(), group)
  end

  defp remote_author do
    {:ok, author} = Bonfire.Me.Users.by_ap_id(@author)
    author
  end

  test "a followers-only comment from a remote instance on a public post in our public group can't be seen by guests or non-followers",
       %{creator: creator, member: member, outsider: outsider, group: group, group_ap_id: group_ap_id} do
    parent = publish_parent(creator, group, "public")
    creator_ap_id = ActivityPub.Actor.get_cached!(pointer: creator).ap_id

    reply =
      parent
      |> incoming_reply(creator, group_ap_id, %{
        to: [@author_followers],
        cc: [group_ap_id, creator_ap_id]
      })
      |> receive_reply()

    # the positive first: whoever it was addressed to can read it
    assert Bonfire.Boundaries.can?(remote_author(), [:see, :read], reply),
           "its own author can't read the comment"

    assert Bonfire.Boundaries.can?(creator, [:see, :read], reply),
           "the parent's author, who the comment names in `cc`, can't read it"

    refute Bonfire.Boundaries.can?(:guest, [:see, :read], reply),
           "a followers-only comment got its public parent's audience, so anyone can read it"

    refute Bonfire.Boundaries.can?(outsider, [:see, :read], reply),
           "a local user who doesn't follow its author can read a followers-only comment"

    refute Bonfire.Boundaries.can?(member, [:see, :read], reply),
           "a member of the group who doesn't follow its author can read a followers-only comment"
  end

  # a local user's follow of a remote author is a request until the author's server accepts it, and only then are they in the author's followers circle
  defp follow_author_accepted(follower) do
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @author)
    author = remote_author()
    assert {:ok, request} = Bonfire.Social.Graph.Follows.follow(follower, author)
    follow_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(request)

    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Accept",
               "id" => "#{@author}/accept/#{id(follower)}",
               "actor" => @author,
               "object" => follow_activity.data,
               "to" => [ActivityPub.Actor.get_cached!(pointer: follower).ap_id]
             })

    assert Bonfire.Social.Graph.Follows.following?(follower, author)
  end

  test "a followers-only comment from a remote instance on a public post in our public group can be read by its author's followers here",
       %{creator: creator, member: member, outsider: outsider, group: group, group_ap_id: group_ap_id} do
    follower = fake_user!()
    follow_author_accepted(follower)

    parent = publish_parent(creator, group, "public")
    assert Bonfire.Boundaries.can?(follower, [:see, :read], parent), "control: the follower can read the parent"
    creator_ap_id = ActivityPub.Actor.get_cached!(pointer: creator).ap_id

    reply =
      parent
      |> incoming_reply(creator, group_ap_id, %{
        to: [@author_followers],
        cc: [group_ap_id, creator_ap_id]
      })
      |> receive_reply()

    # the positive first
    assert Bonfire.Boundaries.can?(follower, [:see, :read], reply),
           "a local follower of its author can't read a followers-only comment on a public post"

    assert Bonfire.Boundaries.can?(creator, [:see, :read], reply)

    refute Bonfire.Boundaries.can?(outsider, [:see, :read], reply)
    refute Bonfire.Boundaries.can?(member, [:see, :read], reply)
    refute Bonfire.Boundaries.can?(:guest, [:see, :read], reply)
  end

  test "a public comment from a remote instance on a members-only post in our public group is members-only",
       %{creator: creator, member: member, outsider: outsider, group: group, group_ap_id: group_ap_id} do
    parent = publish_parent(creator, group, "members:private")

    join_group(group, group_ap_id)

    assert Bonfire.Boundaries.can?(member, [:see, :read], parent)
    refute Bonfire.Boundaries.can?(:guest, [:see, :read], parent)

    reply = parent |> incoming_reply(creator, group_ap_id) |> receive_reply()

    assert Bonfire.Boundaries.can?(member, [:see, :read], reply),
           "a member of the group can't read a comment on a members-only post"

    refute Bonfire.Boundaries.can?(:guest, [:see, :read], reply),
           "a public comment on a members-only post is readable by anyone"

    refute Bonfire.Boundaries.can?(outsider, [:see, :read], reply),
           "a public comment on a members-only post is readable by a non-member"
  end

  test "a comment from a remote instance naming a non-member, on a members-only post in our public group, isn't readable by that non-member but is by the members it names",
       %{creator: creator, member: member, outsider: outsider, group: group, group_ap_id: group_ap_id} do
    parent = publish_parent(creator, group, "members:private")
    join_group(group, group_ap_id)
    refute Bonfire.Boundaries.can?(outsider, [:see, :read], parent), "control: the non-member can't read the parent"

    [creator_ap_id, member_ap_id, outsider_ap_id] =
      Enum.map([creator, member, outsider], &ActivityPub.Actor.get_cached!(pointer: &1).ap_id)

    reply =
      parent
      |> incoming_reply(creator, group_ap_id, %{
        to: [@author_followers],
        cc: [group_ap_id, creator_ap_id, member_ap_id, outsider_ap_id]
      })
      |> receive_reply()

    # the positive first: the members it names can read it
    assert Bonfire.Boundaries.can?(member, [:see, :read], reply),
           "a member of the group named in the comment can't read it"

    assert Bonfire.Boundaries.can?(creator, [:see, :read], reply),
           "the parent's author, named in the comment, can't read it"

    refute Bonfire.Boundaries.can?(outsider, [:see, :read], reply),
           "naming a non-member in a comment on a members-only post let them read it, so the comment is wider than its parent"

    refute Bonfire.Boundaries.can?(:guest, [:see, :read], reply)
  end

  test "a public comment from a remote instance on a public post in our public group is public",
       %{creator: creator, outsider: outsider, group: group, group_ap_id: group_ap_id} do
    parent = publish_parent(creator, group, "public")

    reply = parent |> incoming_reply(creator, group_ap_id) |> receive_reply()

    assert Bonfire.Boundaries.can?(:guest, [:see, :read], reply)
    assert Bonfire.Boundaries.can?(outsider, [:see, :read], reply)
  end
end
