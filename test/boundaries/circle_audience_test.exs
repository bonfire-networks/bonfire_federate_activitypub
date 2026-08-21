defmodule Bonfire.Federate.ActivityPub.CircleAudienceTest do
  @moduledoc """
  Posts whose audience is defined by a circle must address their deliverable recipients in the outgoing payload.

  These assert the TARGET behaviour, so they fail until the addressing fix lands. The current broken behaviour is characterised separately in `test/live_federation/circle_audience_live_test.exs`, which is not re-proved here.

  Chosen semantics, per the plan:

    * a circle grantee is only delivered to if they are mentioned or already follow the author (the existing gate, kept as the default)
    * recipients we do deliver to are addressed silently: present in the audience, with no `Mention` tag, which is what makes Mastodon treat the status as `:limited` rather than `:direct`
    * a circle whose only members are non-followers still produces nothing, exactly like a `"mentions"` post with no mentions
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Posts
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.{Acls, Circles, Grants}
  alias Bonfire.Federate.ActivityPub.Outgoing

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  # a grantee on a SECOND instance, so per-instance narrowing of the audience is observable
  @other_instance "https://other.local"
  @other_actor @other_instance <> "/users/dave"

  setup do
    Process.put(:federating, true)

    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @other_actor} ->
        json(Simulate.actor_json(@other_actor))

      %{method: :get, url: @remote_instance <> "/.well-known/webfinger" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: @remote_instance <> "/.well-known/nodeinfo" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: @other_instance <> "/.well-known/webfinger" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: @other_instance <> "/.well-known/nodeinfo" <> _} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    alice = fake_user!()
    {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(alice.id)
    {:ok, karen_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    {:ok, karen} = Bonfire.Me.Users.by_ap_id(@remote_actor)

    {:ok, alice: alice, alice_actor: alice_actor, karen: karen, karen_actor: karen_actor}
  end

  defp follow!(follower_actor, followed_actor) do
    {:ok, follow_activity} =
      ActivityPub.follow(%{actor: follower_actor, object: followed_actor, local: false})

    {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
  end

  defp publish_with_circle_boundary!(author, member, html_body) do
    {:ok, circle} = Circles.create(author, %{named: %{name: "friends"}})
    {:ok, _} = Circles.add_to_circles(id(member), circle)

    {:ok, acl} = Acls.simple_create(author, "friends only")
    Grants.grant(circle.id, acl.id, [:see, :read], true, current_user: author)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: acl.id
      )

    post
  end

  defp addressing(%{data: data}) do
    List.wrap(data["to"]) ++
      List.wrap(data["cc"]) ++ List.wrap(data["bto"]) ++ List.wrap(data["bcc"])
  end

  defp mention_hrefs(activity) do
    (activity.object || %{})
    |> Map.get(:data, %{})
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Mention"))
    |> Enum.map(& &1["href"])
  end

  describe "a circle grantee who follows the author" do
    test "is addressed in the outgoing payload, without a Mention tag", %{
      alice: alice,
      karen: karen,
      karen_actor: karen_actor,
      alice_actor: alice_actor
    } do
      follow!(karen_actor, alice_actor)

      post = publish_with_circle_boundary!(alice, karen, "circle only, no mentions")

      # preconditions, so a fixture problem cannot masquerade as the behaviour under test
      refute Boundaries.object_public?(post)
      assert [_ | _] = Boundaries.users_grants_on([karen], [post], [:see, :read])

      assert {:ok, activity} = Outgoing.push_now!(post)

      assert karen_actor.ap_id in addressing(activity),
             "expected the circle grantee to be addressed, got: #{inspect(addressing(activity))}"

      refute ActivityPub.Config.public_uri() in addressing(activity),
             "a circle-scoped post must never be addressed publicly"

      refute karen_actor.ap_id in mention_hrefs(activity),
             "the grantee must be addressed silently, with no Mention tag, so Mastodon treats it as :limited rather than :direct"
    end
  end

  describe "a circle grantee who does not follow the author" do
    test "is not delivered to, and the post does not federate at all", %{
      alice: alice,
      karen: karen
    } do
      post = publish_with_circle_boundary!(alice, karen, "circle only, grantee is not a follower")

      assert [_ | _] = Boundaries.users_grants_on([karen], [post], [:see, :read])

      # guards the chosen default: delivery stays gated on mentioned-or-following, so this post has no deliverable recipients and must behave exactly like a "mentions" post with no mentions
      assert_raise RuntimeError, fn -> Outgoing.push_now!(post) end

      assert {:error, _} = ActivityPub.Object.get_cached(pointer: id(post))
    end
  end

  describe "a circle grantee alongside a mention" do
    test "both are addressed, but only the mentioned actor gets a Mention tag", %{
      alice: alice,
      karen: karen,
      karen_actor: karen_actor,
      alice_actor: alice_actor
    } do
      follow!(karen_actor, alice_actor)

      mentioned = fake_user!()
      mentioned_actor = ActivityPub.Actor.get_cached!(pointer: mentioned.id)

      post =
        publish_with_circle_boundary!(
          alice,
          karen,
          "circle post mentioning @#{mentioned.character.username}"
        )

      assert {:ok, activity} = Outgoing.push_now!(post)

      assert mentioned_actor.ap_id in addressing(activity)
      assert karen_actor.ap_id in addressing(activity)

      # the assertion that keeps the two kinds of recipient from being conflated
      assert mentioned_actor.ap_id in mention_hrefs(activity)
      refute karen_actor.ap_id in mention_hrefs(activity)
    end
  end

  describe "the payload each instance actually receives" do
    test "surfaces that instance's grantees in cc, strips bto/bcc, and hides other instances' grantees",
         %{alice: alice, alice_actor: alice_actor, karen: karen, karen_actor: karen_actor} do
      {:ok, dave_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @other_actor)
      {:ok, dave} = Bonfire.Me.Users.by_ap_id(@other_actor)

      follow!(karen_actor, alice_actor)
      follow!(dave_actor, alice_actor)

      {:ok, circle} = Circles.create(alice, %{named: %{name: "friends"}})
      {:ok, _} = Circles.add_to_circles(id(karen), circle)
      {:ok, _} = Circles.add_to_circles(id(dave), circle)

      {:ok, acl} = Acls.simple_create(alice, "friends only")
      Grants.grant(circle.id, acl.id, [:see, :read], true, current_user: alice)

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "two grantees on two instances"}},
          boundary: acl.id
        )

      assert {:ok, activity} = Outgoing.push_now!(post)

      payloads =
        ActivityPub.Federator.APPublisher.prepare_publish_params(alice_actor, activity)
        |> Map.new(fn %{inbox: inbox, json: json} ->
          {URI.parse(inbox).host, Jason.decode!(json)}
        end)

      # both instances are delivered to
      assert %{} = karen_payload = payloads[URI.parse(@remote_actor).host]
      assert %{} = dave_payload = payloads[URI.parse(@other_actor).host]

      for {payload, mine, theirs} <- [
            {karen_payload, karen_actor.ap_id, dave_actor.ap_id},
            {dave_payload, dave_actor.ap_id, karen_actor.ap_id}
          ] do
        audience = List.wrap(payload["to"]) ++ List.wrap(payload["cc"])

        # Mastodon reads only to/cc, so a recipient addressed solely via bcc is invisible to it
        assert mine in audience,
               "expected #{mine} to be addressed in to/cc, got: #{inspect(audience)}"

        # ...but the rest of the circle must not be disclosed to this instance
        refute theirs in audience,
               "expected #{theirs} NOT to be disclosed to another instance, got: #{inspect(audience)}"

        # AP spec 6.11: bto/bcc must be removed before delivery
        refute Map.has_key?(payload, "bcc")
        refute Map.has_key?(payload, "bto")
        refute Map.has_key?(payload["object"] || %{}, "bcc")
        refute Map.has_key?(payload["object"] || %{}, "bto")
      end
    end
  end

  describe "incoming: a Note addressed by audience with no Mention tag" do
    test "grants the addressed local user access, and nobody else" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      recipient = fake_user!()
      bystander = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "content" => "audience addressed, not mentioned",
        "type" => "Note",
        "published" => "2015-02-10T15:00:00Z",
        "attributedTo" => actor.ap_id,
        "to" => [],
        "cc" => [recipient_actor.ap_id],
        "tag" => []
      }

      {:ok, activity} =
        ActivityPub.create(%{
          actor: actor,
          object: object,
          to: [],
          context: nil,
          local: false,
          additional: %{"cc" => [recipient_actor.ap_id]}
        })

      assert {:ok, received} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

      assert [_ | _] = Boundaries.users_grants_on([recipient], [received], [:see, :read])

      assert [] == Boundaries.users_grants_on([bystander], [received], [:see, :read]),
             "a local user absent from the audience must not be granted access"
    end
  end
end
