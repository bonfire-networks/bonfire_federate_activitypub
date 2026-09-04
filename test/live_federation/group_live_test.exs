defmodule Bonfire.Federate.ActivityPub.LiveFederation.GroupLiveTest do
  @moduledoc """
  The OUTBOUND half of group federation: does a real remote accept what one of OUR groups relays?

  Every other live probe has us following them, which only shows what they send. This needs the remote to follow US, and a bore tunnel is not somewhere anyone keeps an account, so the follow is done BY HAND while the test waits. That is why it is opt-in: without a human at the other end it can only time out.

      # a tunnelled dev instance, on a bore port the remote has no failure history against
      LIVE_TEST_HOSTED_GROUP=yes BORE_PORT=7 just test-federation-live-DRAGONS \\
        extensions/bonfire_federate_activitypub/test/live_federation/group_live_test.exs

  Both directions, in one round trip, since they need the same manually made follow:

  1. it prints the group's handle and actor URL and waits for your `Follow`
  2. it publishes a post and asserts on what each shape of the group's announce got back
  3. it asks you to post in the group FROM the remote, and asserts that arrives and is filed as the group's

  `LIVE_TEST_FOLLOW_WAIT` sets how long you get for each pause (default 600s).

  What it CANNOT tell you is whether the remote FILED the post: a 2xx only means the payload was accepted, so check the group in the remote's own UI afterwards. `Bonfire.Federate.ActivityPub.Testing.Interop.Groups.hosted_group_flow/1` is the same flow for IEx, when you want to poke at the result rather than assert on it.

  ⚠️ a remote that has been unable to reach this host backs off per instance (Lemmy waits `1.25^(fail_count - 1)` seconds, capped at a day), so a hostname used in earlier runs can be silently unreachable for hours. That is what `BORE_PORT` is for.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server and the remote fetching back run outside the test process, so the sandbox transaction would hide our group
  @moduletag db_sandbox: false
  # a test that waits on a human waiting on a remote needs to show what is arriving WHILE it waits. Captured logs are printed only on failure and only at the end, which is how the 2026-09-04 run could not say whether a follow attempt reached us at all
  @moduletag capture_log: false

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Testing.Interop

  @opt_in_env "LIVE_TEST_HOSTED_GROUP"
  @wait_env "LIVE_TEST_FOLLOW_WAIT"

  @post_types ["Note", "Page", "Article", "Question"]

  setup do
    Process.put(:federating, true)

    test_pid = self()
    previous = Application.get_env(:activity_pub, :document_observer)

    # forwards each delivery (and its receiver's answer) to the test, while still feeding whatever observer was configured, so `AP_CAPTURE_JSON` keeps recording during a run
    Application.put_env(:activity_pub, :document_observer, fn document, context ->
      if context[:source] == :delivery, do: send(test_pid, {:delivered, document, context})
      if previous, do: ActivityPub.Observer.maybe_observe_with(previous, document, context)
      :ok
    end)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:activity_pub, :document_observer)
        observer -> Application.put_env(:activity_pub, :document_observer, observer)
      end
    end)

    :ok
  end

  describe "a group we host" do
    @tag skip:
           System.get_env(@opt_in_env) in [nil, ""] &&
             "needs a human: set #{@opt_in_env}=yes and follow the handle it prints"
    test "relays our post to a remote follower, and files the post they send back" do
      wait = String.to_integer(System.get_env(@wait_env) || "600")

      creator = fake_user!()
      group = hosted_group(creator)

      IO.puts("""

      ── follow this group from the remote you want to test ─────────
        handle:  @#{group[:username]}
        actor:   #{group[:canonical_url]}
        browse:  #{group[:friendly_url]}
      ───────────────────────────────────────────────────────────────
      waiting #{wait}s for a Follow to arrive …
      """)

      follow =
        Interop.await_incoming([type: "Follow"], seconds: wait) ||
          flunk(
            "no Follow arrived within #{wait}s. Either the follow was never made, or the remote could not fetch and parse our group actor — read the capture for the fetch it made of #{group[:canonical_url]}"
          )

      IO.puts("followed by #{inspect(follow.data["actor"])} — publishing now")

      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: creator,
                 post_attrs: %{
                   post_content: %{
                     html_body:
                       "<p>Bonfire group relay probe #{System.unique_integer([:positive])}</p>"
                   }
                 },
                 publish_in: uid(group[:category]),
                 boundary: "public"
               )

      post_ap_id =
        Interop.outgoing_json(post)["id"] ||
          flunk("no outgoing AP id for the post — did federation prepare it?")

      announces = delivered_announces(group[:canonical_url])

      assert announces != [],
             "the group delivered no Announce at all for #{post_ap_id}, so the follower was never treated as a recipient"

      shapes = Enum.map(announces, &announced_type(&1.document))

      assert "Create" in shapes,
             "no `Announce{Create{…}}` went out, which is the only shape Lemmy files. Shapes sent: #{inspect(shapes)}"

      assert Enum.any?(shapes, &(&1 in @post_types)),
             "no announce of the object itself went out, which is the only shape the Pleroma/Misskey/GoToSocial family reads. Shapes sent: #{inspect(shapes)}"

      # NOT every shape has to be accepted: a receiver understands one of the two and refuses the other, which is the whole reason both go out. Lemmy 400s `Announce{Note}` ("Failed to parse incoming activity") and that is the expected answer from it, not a defect. What would be a defect is NEITHER landing, since then the group cannot reach that remote at all.
      accepted = Enum.filter(announces, &(&1.status in 200..299))

      results =
        Enum.map(announces, fn a -> {announced_type(a.document), a.status} end)

      assert accepted != [],
             "the remote refused BOTH shapes, so nothing we relay can reach it: #{inspect(Enum.map(announces, &{announced_type(&1.document), &1.status, &1.body}))}"

      IO.puts("""

      delivered #{length(announces)} announces to #{inspect(Enum.map(announces, & &1.inbox) |> Enum.uniq())}: #{inspect(results)}
      #{Enum.map_join(Enum.reject(announces, &(&1.status in 200..299)), "\n", fn a -> "  refused `Announce{#{announced_type(a.document)}}` HTTP #{a.status}: #{inspect(a.body)}" end)}
      a 2xx only means the payload was accepted, not that the post was filed — so look for it in the group before doing the next step
      """)

      # THE OTHER DIRECTION, which the outbound half cannot stand in for: a member posting from their own instance is how a group gets used, and it exercises ingest (does the post reach us at all), attribution (do we file it in the group rather than as a stray post) and the relay (do we then announce it to the group's OTHER followers)
      IO.puts("""

      ── now post in the group FROM the remote ──────────────────────
        the same community you just followed: #{group[:username]}
      ───────────────────────────────────────────────────────────────
      waiting #{wait}s for it to arrive …
      """)

      incoming =
        Interop.await_incoming([type: "Create", audience: group[:canonical_url]], seconds: wait) ||
          flunk(
            "no post addressed to #{group[:canonical_url]} arrived within #{wait}s. It may have been delivered and REJECTED rather than never sent, which `incoming/1` cannot show: re-run with `AP_CAPTURE_JSON` set to see the payload"
          )

      # naming the SHAPE, because a comment and a thread starter take different paths in and only one of them exercises attribution by `audience`: a reply is already attributed through the thread it is in. On 2026-09-04 a run reported the inbound half working when what had been sent was a comment on our own post
      object = incoming.data["object"]

      IO.puts("""
      received #{inspect(incoming.data["id"])} from #{inspect(incoming.data["actor"])}
        object:      #{if is_binary(object), do: "#{object} (sent as a bare id, so its type is only known once fetched)", else: inspect(e(object, "type", nil))}
        inReplyTo:   #{inspect(e(object, "inReplyTo", nil))} #{if e(object, "inReplyTo", nil), do: "← a COMMENT, so the group came from its thread rather than from `audience`", else: "← a thread starter, which is the case `audience` attribution is for"}
      """)

      remote_object_id =
        ActivityPub.Object.get_ap_id(incoming.data["object"]) ||
          flunk("the Create carries no object: #{inspect(incoming.data)}")

      pointer_id =
        Interop.await_pointer(remote_object_id, seconds: 60) ||
          flunk(
            "#{remote_object_id} was stored as an AP object but never became a local one, so it exists to federation and not to Bonfire"
          )

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, pointer_id,
               by: group[:category],
               current_user: creator
             ),
             "the post arrived but is not in the group's feed, so we ingested it as a stray post rather than as the group's"

      # informational: whether we relay a member's post on to the group's other followers, which is the group's whole job and is asserted for LOCAL posts in `group_outgoing_test.exs`
      {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: remote_object_id)

      case ActivityPub.Object.get_existing_announce(group[:canonical_url], ap_object) do
        %{data: %{"id" => id}} -> IO.puts("and the group announced it on: #{id}")
        other -> IO.puts("the group did NOT announce it: #{inspect(other)}")
      end
    end
  end

  defp hosted_group(creator) do
    group = Simulate.fancy_fake_category!(creator, type: :group)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group[:category], creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    group
  end

  # everything the observer forwarded while we published, narrowed to announces BY THE GROUP: the same publish also delivers the author's own Create, which is not what this is about
  defp delivered_announces(group_ap_id) do
    collect_deliveries([])
    |> Enum.filter(fn %{document: document} ->
      document["type"] == "Announce" and
        ActivityPub.Object.get_ap_id(document["actor"]) == group_ap_id
    end)
  end

  defp collect_deliveries(acc) do
    receive do
      {:delivered, document, context} ->
        collect_deliveries([
          %{
            document: document,
            inbox: context[:url],
            status: context[:status],
            body: context[:body]
          }
          | acc
        ])
    after
      # publishing is synchronous under `FEDERATE=yes` (Oban runs inline), so this only covers the tail of a delivery still in flight
      5_000 -> Enum.reverse(acc)
    end
  end

  defp announced_type(%{"object" => %{"type" => type}}), do: type
  defp announced_type(%{"object" => object}) when is_binary(object), do: :bare_id
  defp announced_type(_), do: nil
end
