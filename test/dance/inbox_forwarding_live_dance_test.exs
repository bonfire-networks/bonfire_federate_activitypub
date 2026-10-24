defmodule Bonfire.Federate.ActivityPub.Dance.InboxForwardingLiveTest do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2) with three servers: the account on a real server follows our user, a user on the dance's other instance replies to our user's post, and we forward the reply to the real server, which shows it under the post (the post's context, through its Mastodon-compatible API).

  The forward carries the replier's FEP-8b32 proof and our user's HTTP signature, so a server that shows the reply relied on the proof: the HTTP signer is not the reply's author. Mastodon reads such a proof (`actor_from_verified_object_integrity_proof`), and so does Mitra.

  Both dance instances must be reachable from the real server (it fetches the replier's key from the other instance), so it runs through the recipe that tunnels both:

      just test-federation-live-dance-DRAGONS extensions/bonfire_federate_activitypub/test/dance/inbox_forwarding_live_dance_test.exs

  The accounts are the `.env` ones of `live_federation/proofs_live_test.exs`; a server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits.

  ⚠️ It acts as a real person: the account follows a test user here, and unfollows when the test ends.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false
  use Repatch.ExUnit

  # not `:test_instance`: it acts as real people, so it runs through the live recipe only, never in `--only test_instance` dance runs
  @moduletag :live_federation
  @moduletag capture_log: false

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias ActivityPub.Federator.Forwarder
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows

  # the servers that verify FEP-8b32 proofs and have a Mastodon-compatible API to read back what they did
  @servers ~w(mitra mastodon)

  setup context do
    Process.put(:federating, true)
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)

    clean_slate(context)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:activity_pub, :sign_object_integrity_proofs),
        else: Application.put_env(:activity_pub, :sign_object_integrity_proofs, orig)
    end)
  end

  for name <- @servers do
    @tag skip:
           MastodonApi.from_env(name) == nil &&
             "set LIVE_TEST_#{String.upcase(name)}_URL and LIVE_TEST_#{String.upcase(name)}_TOKEN in .env"
    @tag timeout: :timer.minutes(40)
    test "#{name}: a reply from the other instance to our user's post is forwarded to #{name}, which shows it under the post",
         context do
      run(unquote(name), context)
    end
  end

  defp run(name, context) do
    api = MastodonApi.from_env(name)
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")
    alice = context[:local][:user]
    alice_url = context[:local][:canonical_url]
    server_host = URI.parse(api.base).host

    # what the receiver decided about forwarding each activity, watched as it happens (it still runs); `:global`, as the receiving instance's processes are not this test's
    test_pid = self()

    Repatch.patch(Forwarder, :maybe_forward, [mode: :global], fn received, result, forwarding ->
      send(test_pid, {:forwarding, received["id"], received["type"], forwarding})
      Repatch.real(Forwarder.maybe_forward(received, result, forwarding))
    end)

    # signed by its author (FEP-8b32), as only such a reply is forwarded
    Application.put_env(:activity_pub, :sign_object_integrity_proofs, true)

    # the account there follows our user
    # the server fetches our user through the tunnel, which can take longer than one API request waits, so it is asked again until it knows them
    alice_there =
      await(
        fn ->
          case MastodonApi.resolve_account(api, alice_url) do
            {:ok, account} -> account
            _ -> nil
          end
        end,
        wait
      ) || flunk("#{name} could not look up #{alice_url} within #{wait}s")

    {:ok, _} = MastodonApi.follow(api, alice_there["id"]) |> ok_or_flunk("following #{alice_url}")

    try do
      Interop.await_incoming([type: "Follow", about: alice_url], seconds: wait) ||
        flunk("no Follow from #{name} reached us within #{wait}s")

      # a user on the other instance follows ours too, so our post reaches the replier's instance
      TestInstanceRepo.apply(fn ->
        assert {:ok, alice_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(alice_url)
        assert {:ok, _follow} = Follows.follow(context[:remote][:user], alice_on_remote)
      end)

      text = "a post to reply to #{System.unique_integer([:positive])}"

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "public"
        )

      post_ap_id = Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)

      # on the server, our user's post, as its follower sees it
      post_there =
        await(fn -> on_home_timeline(api, post_ap_id) end, wait) ||
          flunk("our post never reached #{name}'s home timeline within #{wait}s")

      # the user on the other instance replies to it
      reply_ap_id =
        TestInstanceRepo.apply(fn ->
          replier = fancy_fake_user!("Replier")[:user]

          assert activity =
                   Bonfire.Social.FeedLoader.feed_contains?(:my, text,
                     current_user: context[:remote][:user]
                   )

          assert {:ok, reply} =
                   Posts.publish(
                     current_user: replier,
                     post_attrs: %{
                       post_content: %{html_body: "a reply from the other instance"},
                       reply_to_id: activity.object.id
                     },
                     boundary: "public"
                   )

          Bonfire.Common.URIs.canonical_url(reply, preload_if_needed: true)
        end)

      # we forward it to the server's inbox
      assert_receive {:forwarding, _id, "Create", {:ok, %{inboxes: inboxes}}}, wait * 1000

      assert Enum.any?(inboxes, &(URI.parse(&1).host == server_host)),
             "the reply was forwarded, but not to #{name}: #{inspect(inboxes)}"

      # and the server, trusting the replier's proof, shows the reply under our user's post
      assert await(fn -> reply_in_context?(api, post_there["id"], reply_ap_id) end, wait),
             "#{name} never showed the forwarded reply #{reply_ap_id} under #{post_ap_id} within #{wait}s"
    after
      case MastodonApi.unfollow(api, alice_there["id"]) do
        {:ok, _} ->
          IO.puts("cleanup: #{name} unfollowed #{alice_url}")

        other ->
          IO.puts("cleanup FAILED: could not unfollow #{alice_url} on #{name}: #{inspect(other)}")
      end
    end
  end

  # the home-timeline status that is the post with this AP id; nil when not there yet, so `await/2` tries again
  defp on_home_timeline(api, ap_id) do
    case MastodonApi.home_timeline(api, limit: 40) do
      {:ok, statuses} -> Enum.find(statuses, &(&1["uri"] == ap_id))
      _ -> nil
    end
  end

  defp reply_in_context?(api, status_id, reply_ap_id) do
    case MastodonApi.status_context(api, status_id) do
      {:ok, %{"descendants" => descendants}} ->
        Enum.any?(descendants, &(&1["uri"] == reply_ap_id))

      _ ->
        false
    end
  end

  # polls every 5 seconds; the result of `fun` once it is neither nil, false nor [], else nil after `seconds`
  defp await(fun, seconds) do
    deadline = System.monotonic_time(:second) + seconds
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      result when result not in [nil, false, []] ->
        result

      _ ->
        if System.monotonic_time(:second) >= deadline do
          nil
        else
          Process.sleep(5_000)
          do_await(fun, deadline)
        end
    end
  end

  defp ok_or_flunk({:ok, _} = ok, _what), do: ok
  defp ok_or_flunk(other, what), do: flunk("#{what} failed: #{inspect(other)}")
end
