defmodule Bonfire.Federate.ActivityPub.LiveFederation.CircleAudienceLiveTest do
  @moduledoc """
  Characterises the CURRENT (broken) behaviour of posts whose audience is defined by a circle, against a real remote instance.

  These tests assert what happens today, not what should happen. They exist to confirm the diagnosis empirically before any fix is written, and are expected to be inverted once the outgoing addressing is fixed.

  Two documented symptoms:

    * a post with only circle grants never federates at all, because it ships with an empty audience and `Bonfire.Federate.ActivityPub.BoundariesMRF` drops it inside `ActivityPub.Object.insert` before any row is written
    * a post with circle grants plus any mention does federate and IS delivered to circle members who follow the author, but they are absent from the payload's addressing, so the receiving instance has no reason to show it to them

  Requires `LIVE_TEST_MASTODON_ACTOR` to be set to the AP id of a real remote actor, e.g. `https://mastodon.social/users/someone`. Run with:

      just test-federation-live-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation

  which opens a bore tunnel so the remote instance can fetch back our actor and verify signatures.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server and the remote instance fetching back run outside the test process, so the sandbox transaction would hide our actors
  @moduletag db_sandbox: false

  import Ecto.Query

  alias Bonfire.Posts
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.{Acls, Circles, Grants}
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias ActivityPub.Federator.APPublisher

  @recipient_env "LIVE_TEST_MASTODON_ACTOR"

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp remote_recipient_ap_id! do
    System.get_env(@recipient_env) ||
      flunk("""
      Set #{@recipient_env} to the AP id of a real remote actor you control, e.g.
        #{@recipient_env}=https://mastodon.social/users/you
      For the timeline half of this check, that account should already follow the tunnelled test user.
      """)
  end

  defp remote_recipient! do
    ap_id = remote_recipient_ap_id!()

    case AdapterUtils.get_or_fetch_and_create_by_uri(ap_id) do
      {:ok, user} -> user
      other -> flunk("Could not fetch remote actor #{ap_id}: #{inspect(other)}")
    end
  end

  # a custom, non-public boundary granting see+read to a circle containing `member`
  defp publish_with_circle_boundary!(author, member, html_body) do
    {:ok, circle} = Circles.create(author, %{named: %{name: "live test friends"}})
    {:ok, _} = Circles.add_to_circles(id(member), circle)

    {:ok, acl} = Acls.simple_create(author, "live test friends only")
    Grants.grant(circle.id, acl.id, [:see, :read], true, current_user: author)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: acl.id
      )

    post
  end

  defp ap_object_rows(post) do
    Bonfire.Common.Repo.all(
      from(o in ActivityPub.Object,
        where: o.pointer_id == ^id(post),
        select: %{
          pointer_id: o.pointer_id,
          type: fragment("?->>'type'", o.data),
          to: fragment("?->'to'", o.data),
          cc: fragment("?->'cc'", o.data)
        }
      )
    )
  end

  defp addressing(%{data: data}) do
    List.wrap(data["to"]) ++
      List.wrap(data["cc"]) ++ List.wrap(data["bto"]) ++ List.wrap(data["bcc"])
  end

  describe "circle-scoped posts against a real remote instance" do
    test "row 1: a post with only circle grants federates and addresses its grantee" do
      alice = fake_user!()
      bob = remote_recipient!()
      bob_ap_id = remote_recipient_ap_id!()

      # bob follows alice, so bob is a deliverable recipient under the mentioned-or-following gate
      assert {:ok, _} = Follows.follow(bob, alice)
      assert Follows.following?(bob, alice)

      post = publish_with_circle_boundary!(alice, bob, "live circle-only post, no mentions")

      # preconditions, so a fixture problem cannot masquerade as a pass
      refute Boundaries.object_public?(post)
      assert [_ | _] = Boundaries.users_grants_on([bob], [post], [:see, :read])

      # before the fix this was `[]`: the empty audience made BoundariesMRF return :ignore, so Object.insert never wrote a row
      assert [%{}] = ap_object_rows(post),
             "expected an AP object to exist for a circle-only post"

      assert {:ok, ap_object} = ActivityPub.Object.get_cached(pointer: id(post))
      activity = ActivityPub.Object.get_activity_for_object_ap_id(ap_object.data["id"])

      assert bob_ap_id in addressing(activity),
             "expected the circle grantee to be addressed, got: #{inspect(addressing(activity))}"

      refute ActivityPub.Config.public_uri() in addressing(activity)
    end

    test "row 2: a post with circle grants plus a mention addresses both the mentioned actor and the grantee" do
      alice = fake_user!()
      bob = remote_recipient!()
      bob_ap_id = remote_recipient_ap_id!()

      assert {:ok, _} = Follows.follow(bob, alice)

      # any mention makes `cc` non-empty, enough for the activity to survive MRF
      mentioned = fake_user!()

      post =
        publish_with_circle_boundary!(
          alice,
          bob,
          "live circle post mentioning @#{mentioned.character.username}"
        )

      refute Boundaries.object_public?(post)
      assert [_ | _] = Boundaries.users_grants_on([bob], [post], [:see, :read])

      # unlike row 1, an AP object now exists
      assert [%{} = row] = ap_object_rows(post)
      assert {:ok, ap_object} = ActivityPub.Object.get_cached(pointer: id(post))

      activity = ActivityPub.Object.get_activity_for_object_ap_id(ap_object.data["id"])
      assert %ActivityPub.Object{} = activity

      addressing =
        List.wrap(activity.data["to"]) ++
          List.wrap(activity.data["cc"]) ++
          List.wrap(activity.data["bto"]) ++ List.wrap(activity.data["bcc"])

      # the fix in one assertion: bob is granted see+read and follows alice, so he is addressed in the payload rather than only in the envelope
      assert bob_ap_id in addressing,
             "expected the circle member to be addressed, got: #{inspect(addressing)}"

      refute ActivityPub.Config.public_uri() in addressing

      {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(id(alice))
      params = APPublisher.prepare_publish_params(alice_actor, activity)
      inboxes = Enum.map(params, & &1.inbox)

      {:ok, bob_actor} = ActivityPub.Actor.get_cached(ap_id: bob_ap_id)

      # `prepare_publish_params` uses the personal inbox when an inbox has a single recipient, and the sharedInbox only when it batches several, so accept either
      bob_inboxes =
        [bob_actor.data["inbox"], get_in(bob_actor.data, ["endpoints", "sharedInbox"])]
        |> Enum.reject(&is_nil/1)

      delivered = Enum.filter(params, &(&1.inbox in bob_inboxes))

      assert delivered != [],
             "expected one of the circle member's inboxes #{inspect(bob_inboxes)} to receive it, got: #{inspect(inboxes)}"

      # what the remote instance ACTUALLY receives, which is the part that matters for Mastodon: it derives a status's audience from `to`/`cc` only, and AP spec 6.11 requires `bto`/`bcc` to be stripped before delivery
      for %{inbox: inbox, json: json} <- delivered do
        payload = Jason.decode!(json)

        assert bob_ap_id in (List.wrap(payload["to"]) ++ List.wrap(payload["cc"])),
               "expected the grantee in to/cc of the payload delivered to #{inbox}, got to: #{inspect(payload["to"])} cc: #{inspect(payload["cc"])}"

        refute Map.has_key?(payload, "bcc")
        refute Map.has_key?(payload, "bto")

        IO.puts("""

        === payload delivered to #{inbox} ===
        #{json}
        === for the timeline half, check #{bob_ap_id}'s Mastodon account by hand ===
        """)
      end

      # the row carrying the post's pointer_id is the Note; the wrapping Create is inserted without a pointer
      assert row.type == "Note"
    end
  end
end
