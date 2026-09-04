defmodule Bonfire.Federate.ActivityPub.LiveFederation.GroupInteropLiveTest do
  @moduledoc """
  Live interop probe against a REAL threadiverse group (a Lemmy community by default), for the public group federation plan's pass-3.

  Oban runs `:inline` and Tesla is un-mocked under `FEDERATE=yes` (set by the tunnel recipe), so the normal code paths deliver synchronously here and we can assert on what the remote actually does, rather than on our own publish plumbing.

  Set the target and run:

      LIVE_TEST_GROUP='!test5677754@lemmy.world' just test-federation-live-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/group_interop_live_test.exs

  The bore tunnel matters: these remotes fetch our actor back (signed) before accepting anything, so without it nothing can succeed. All the probing/polling lives in `Bonfire.Federate.ActivityPub.Testing.Interop` (+ `.Groups`) so it can be reused from IEx.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server and the remote fetching back run outside the test process, so the sandbox transaction would hide our actors
  @moduletag db_sandbox: false

  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Federate.ActivityPub.Testing.Interop.Groups

  @group_env "LIVE_TEST_GROUP"

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp group_handle! do
    System.get_env(@group_env) ||
      flunk("""
      Set #{@group_env} to a real remote group, eg.
        #{@group_env}='!test5677754@lemmy.world'
      """)
  end

  describe "remote group actor" do
    test "is fetchable and carries the FEP-1b12 shape we expect" do
      assert {:ok, actor} = Interop.fetch(group_handle!())

      assert actor.data["type"] == "Group",
             "expected a Group actor, got #{inspect(actor.data["type"])}"

      assert actor.data["inbox"]

      # NOTE: note asserting `followers`: it's a threadiverse convention rather than a requirement. NodeBB categories publish none (and serve the ACTOR document, 200, at the conventional URL) yet still Accept our Follow, and the only place we read a remote's followers is FEP-171b `automaticApproval` matching, where absent just means no match.

      # 1b12 §Group moderation: moderators are exposed as an attributedTo collection
      assert actor.data["attributedTo"],
             "no attributedTo moderators collection — recheck the pass-1 finding for this platform"
    end
  end

  describe "the group's outbox" do
    # How to learn a platform's fan-out shape WITHOUT waiting on someone to post: its outbox already holds the Announces it emitted. Run with `AP_CAPTURE_JSON` and both the collection and its first page are captured verbatim, which is where the per-platform announce fixtures come from.
    test "is fetchable and shows the announce shape it fans out" do
      handle = group_handle!()
      {:ok, group} = Interop.fetch(handle)

      outbox_url =
        e(group, :data, "outbox", nil) ||
          flunk("group advertises no outbox: #{inspect(group.data)}")

      assert {:ok, outbox} = fetch_json(outbox_url),
             "could not fetch #{outbox_url} — Mbin and others require a signed fetch, so this needs the tunnel"

      # outboxes are paged: the collection itself normally carries only `first`
      {:ok, page} =
        case outbox["first"] do
          url when is_binary(url) -> fetch_json(url)
          %{} = embedded -> {:ok, embedded}
          _ -> {:ok, outbox}
        end

      items = page["orderedItems"] || page["items"] || []

      types = items |> Enum.map(& &1["type"]) |> Enum.frequencies()
      IO.inspect(types, label: "outbox activity types for #{handle}")

      assert items != [],
             "outbox is empty or unpaged (#{inspect(Map.take(outbox, ["type", "totalItems", "first"]))}) — nothing to learn about its announce shape"
    end

    # the lib's raw-JSON fetch, so the `:document_observer` sees the wire bytes (`fetch_collection/2` would ingest every entry, which a probe has no business doing)
    defp fetch_json(url) do
      ActivityPub.Federator.Fetcher.get_cached_or_fetch_object_json(url,
        skip_contain_origin_check: true
      )
    end
  end

  describe "joining" do
    # REGRESSION GUARD: a Follow round-trip only completes if the remote can fetch and PARSE our actor.
    # This is what caught our `updated` field being serialised without a timezone (AS2 Core §2.3 requires RFC3339 with `Z`), which made Lemmy reject the whole actor with HTTP 400 and silently blocked every interaction with Lemmy instances.
    test "the remote Accepts our Follow (proving it can fetch and parse our actor)" do
      handle = group_handle!()
      me = fake_user!()

      assert {:ok, request} = Interop.follow(handle, as: me)
      {:ok, group} = Interop.fetch(handle)

      # deterministic half, independent of the remote: `object` must stay a bare id. Implementations type a Follow's object as a link, so embedding the actor (which `prepare_outgoing_object/1` used to do by normalising the id back into cached JSON) makes them reject it outright.
      follow_json = Interop.outgoing_json(request) || %{}

      assert is_binary(follow_json["object"]),
             "our Follow embeds the target actor instead of referencing its id: #{inspect(follow_json["object"])}"

      # generous: this is usually FIRST contact with the remote, which has to fetch and parse our
      # actor before it can accept, and a large instance queues that work. The 90s default is not
      # enough against lemmy.world even from a host it has no backoff against
      assert Interop.await_incoming([type: "Accept", from: group.ap_id], seconds: 300),
             "no Accept received from #{group.ap_id} — the remote could not parse/verify our Follow or our actor"
    end
  end

  describe "posting into a remote group" do
    # EXPECTED TO FAIL until the plan's phase 3 (outgoing `audience` + group in to/cc): we currently emit no reference to the group at all, so there is nothing for the remote to attribute.
    # Kept as the acceptance test for that phase.
    test "a post addressed to the group comes back announced by the group" do
      handle = group_handle!()
      me = fake_user!()

      # against a mods-only group NO non-mod post can be accepted, so a failure below would say nothing about our addressing
      refute Groups.posting_restricted?(handle),
             "#{handle} only accepts posts from its moderators — set #{@group_env} to an open group"

      {:ok, group} = Interop.fetch(handle)

      # join first: not required by Lemmy (its `verify_person_in_community` is a ban check, not a membership one), but it's what a real user does and other platforms do gate on membership
      Interop.follow(handle, as: me)

      # a SECOND follower who is not the author. Lemmy announces to community followers, and the open question is whether the author is skipped: with someone else following too, an announce that arrives proves the fan-out reaches us and only the author was excluded, while still nothing points elsewhere, either Lemmy skipping our whole instance as the post's origin, or our own ingest declining to store an announce whose inner object is already local
      lurker = fake_user!()
      Interop.follow(handle, as: lurker)

      # and WAIT for the Accept before posting. The group announces a new post to its followers at the moment it accepts the post, so posting before we are a follower means the announce is sent to everyone except us and the assertion below fails while everything actually worked, which is exactly what happened on 2026-09-04, when the post appeared on lemmy.world and nothing came back
      assert Interop.await_incoming([type: "Accept", from: group.ap_id], seconds: 180),
             "never became a follower, so no announce can reach us"

      assert {:ok, post} =
               Interop.post_to(
                 handle,
                 "<p>Bonfire interop probe #{System.unique_integer([:positive])}</p>",
                 as: me
               )

      post_ap_id =
        Interop.outgoing_json(post)["id"] ||
          flunk("no outgoing AP id for the post — did federation prepare it?")

      assert Interop.await_incoming([type: "Announce", from: group.ap_id, about: post_ap_id],
               # generous on purpose: a large instance queues outgoing federation, and we are a brand new unknown host it has no delivery history with
               seconds: 300
             ),
             "the group never announced our post back. Check the community in a browser before believing this: on 2026-09-04 the post WAS there and the announce simply never reached us"
    end

    # Splits the problem in half. A top-level post is rejected by Lemmy because their `Note` IS their comment type and requires `inReplyTo`, so a thread-starter has to be a `Page`, but a REPLY is a `Note` with an `inReplyTo`, which is exactly what we already emit. So replies may already work where posts cannot, and that is worth knowing before building per-receiver type transformation.
    test "a reply to an existing post in the group comes back announced" do
      handle = group_handle!()
      me = fake_user!()
      {:ok, group} = Interop.fetch(handle)

      parent_id =
        first_post_id(group) ||
          flunk(
            "#{handle} has no posts to reply to — set #{@group_env} to a community with content"
          )

      assert {:ok, %{pointer_id: parent_pointer}} =
               ActivityPub.Federator.Fetcher.fetch_object_from_id(parent_id)

      assert is_binary(parent_pointer),
             "ingested #{parent_id} but it has no local pointer to reply to"

      Interop.follow(handle, as: me)

      assert {:ok, reply} =
               Bonfire.Posts.publish(
                 current_user: me,
                 post_attrs: %{
                   reply_to_id: parent_pointer,
                   post_content: %{
                     html_body: "<p>Bonfire reply probe #{System.unique_integer([:positive])}</p>"
                   }
                 },
                 publish_in: uid(group),
                 boundary: "public"
               )

      reply_ap_id =
        Interop.outgoing_json(reply)["id"] || flunk("no outgoing AP id for the reply")

      assert Interop.await_incoming([type: "Announce", from: group.ap_id, about: reply_ap_id],
               # generous on purpose: a large instance queues outgoing federation, and we are a brand
               # new unknown host it has no delivery history with
               seconds: 300
             ),
             "the group never announced our reply back. Read the delivery captures for the status and body: a 400 here means our `Note` is wrong in some way beyond the thread-starter type"
    end

    # the newest announced object in the community's outbox, which is what a real reply targets
    defp first_post_id(group) do
      with outbox_url when is_binary(outbox_url) <- e(group, :data, "outbox", nil),
           {:ok, outbox} <- fetch_json(outbox_url),
           {:ok, page} <-
             (case outbox["first"] do
                url when is_binary(url) -> fetch_json(url)
                %{} = embedded -> {:ok, embedded}
                _ -> {:ok, outbox}
              end) do
        (page["orderedItems"] || page["items"] || [])
        |> Enum.find_value(fn item -> e(item, "object", "object", "id", nil) end)
      else
        _ -> nil
      end
    end
  end
end
