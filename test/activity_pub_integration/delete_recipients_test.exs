defmodule Bonfire.Federate.ActivityPub.DeleteRecipientsTest do
  @moduledoc """
  Who a post's `Delete` is sent to.

  A public post may have reached any of the author's followers, so its `Delete` goes to all of them. A post that was not public only reached who it was addressed to and the followers allowed to see it, so its `Delete` goes to them alone: other instances never had it, and sending it to them only fills the federation queue.

  Each remote actor lives on its own instance, so the instance an inbox belongs to tells which actor it was sent for.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Posts
  alias Bonfire.Boundaries.{Acls, Circles, Grants}
  alias Bonfire.Federate.ActivityPub.Outgoing
  alias ActivityPub.Federator.APPublisher

  # a follower the post is shared with
  @allowed_actor "https://mocked.local/users/karen"
  # a follower the post is not shared with
  @other_follower_actor "https://other.local/users/dave"
  # someone who does not follow the author, mentioned in the post
  @mentioned_actor "https://third.local/users/sam"

  setup do
    Process.put(:federating, true)

    # `.local` is not a known TLD, so a mention of someone on a `.local` host is not parsed unless domain validation is off
    previous = System.get_env("SKIP_LINK_DOMAINS_VALIDATION")
    System.put_env("SKIP_LINK_DOMAINS_VALIDATION", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("SKIP_LINK_DOMAINS_VALIDATION", previous),
        else: System.delete_env("SKIP_LINK_DOMAINS_VALIDATION")
    end)

    mock(fn
      %{method: :get, url: @allowed_actor} ->
        json(Simulate.actor_json(@allowed_actor))

      %{method: :get, url: @other_follower_actor} ->
        json(Simulate.actor_json(@other_follower_actor))

      %{method: :get, url: @mentioned_actor} ->
        json(Simulate.actor_json(@mentioned_actor, "sam"))

      # so the mention in the post resolves to that actor
      %{method: :get, url: "https://third.local/.well-known/webfinger" <> _} ->
        json(Simulate.webfingered("sam", @mentioned_actor))

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    alice = fake_user!()
    {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(alice.id)

    {:ok, allowed_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @allowed_actor)
    {:ok, allowed} = Bonfire.Me.Users.by_ap_id(@allowed_actor)
    {:ok, other_follower_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @other_follower_actor)
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @mentioned_actor)
    {:ok, mentioned} = Bonfire.Me.Users.by_ap_id(@mentioned_actor)

    follow!(allowed_actor, alice_actor)
    follow!(other_follower_actor, alice_actor)

    {:ok, alice: alice, alice_actor: alice_actor, allowed: allowed, mentioned: mentioned}
  end

  defp follow!(follower_actor, followed_actor) do
    {:ok, follow_activity} =
      ActivityPub.follow(%{actor: follower_actor, object: followed_actor, local: false})

    {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
  end

  defp publish!(author, html_body, boundary) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: boundary
      )

    assert {:ok, _} = Outgoing.push_now!(post)
    post
  end

  defp circle_acl!(author, member) do
    {:ok, circle} = Circles.create(author, %{named: %{name: "friends"}})
    {:ok, _} = Circles.add_to_circles(id(member), circle, skip_boundary_check: true)
    {:ok, acl} = Acls.simple_create(author, "friends only")
    Grants.grant(circle.id, acl.id, [:see, :read], true, current_user: author)
    acl.id
  end

  # deletes the post, and gives back its `Delete` and the instances that `Delete` is delivered to
  defp delete!(post, author, author_actor) do
    {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

    assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: author)

    assert %{} = delete = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete")

    hosts =
      APPublisher.prepare_publish_params(author_actor, delete)
      |> Enum.map(&URI.parse(&1.inbox).host)
      |> Enum.uniq()

    {delete, hosts}
  end

  defp host(ap_id), do: URI.parse(ap_id).host

  test "a public post's Delete reaches every remote follower", %{
    alice: alice,
    alice_actor: alice_actor
  } do
    post = publish!(alice, "<p>for everyone</p>", "public")

    {delete, hosts} = delete!(post, alice, alice_actor)

    assert ActivityPub.Config.public_uri() in List.wrap(delete.data["to"])
    assert host(@allowed_actor) in hosts, "got #{inspect(hosts)}"
    assert host(@other_follower_actor) in hosts, "got #{inspect(hosts)}"
  end

  test "a non-public post's Delete reaches the followers allowed to see it, and no other follower",
       %{alice: alice, alice_actor: alice_actor, allowed: allowed} do
    post = publish!(alice, "<p>for friends</p>", circle_acl!(alice, allowed))

    {delete, hosts} = delete!(post, alice, alice_actor)

    refute ActivityPub.Config.public_uri() in List.wrap(delete.data["to"]),
           "got #{inspect(delete.data["to"])}"

    assert host(@allowed_actor) in hosts, "got #{inspect(hosts)}"
    refute host(@other_follower_actor) in hosts, "got #{inspect(hosts)}"
  end

  test "a mentions-only post's Delete reaches who it mentions, and no follower", %{
    alice: alice,
    alice_actor: alice_actor,
    mentioned: mentioned
  } do
    post = publish!(alice, "just for @#{mentioned.character.username}", "mentions")

    {delete, hosts} = delete!(post, alice, alice_actor)

    refute ActivityPub.Config.public_uri() in List.wrap(delete.data["to"]),
           "got #{inspect(delete.data["to"])}"

    assert host(@mentioned_actor) in hosts, "got #{inspect(hosts)}"
    refute host(@allowed_actor) in hosts, "got #{inspect(hosts)}"
    refute host(@other_follower_actor) in hosts, "got #{inspect(hosts)}"
  end
end
