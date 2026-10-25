defmodule Bonfire.Federate.ActivityPub.LiveFederation.ProofsLiveTest do
  @moduledoc """
  FEP-8b32 object integrity proofs with real servers, as a person there sees it through the server's Mastodon-compatible API.

    * incoming: a post made on the server, delivered to our user who follows the account, carries a proof that verifies as its author, on a server that signs what it delivers (Mitra); on one that does not (Mastodon), it carries none, which is fine
    * outgoing: our user's post mentioning the account there goes out with our proof, the server answers 2xx and lists it among our user's statuses, with our HTTP signature and without one; without one, our proof is the only thing the server can rely on

  What arrives and what we send are read through `ActivityPub.Observer`, as nothing else keeps a document as it was on the wire.

  Whether a server relies on our proof when it cannot rely on the HTTP signature (a forwarded reply) is `inbox_forwarding_live_test.exs`.

  It needs an account on each server and a bore tunnel, so the server can fetch our actor back. Put the URL and an access token (scopes `read`, `write`, `follow`) in the git-ignored `.env`, one pair per server, and run it through the tunnel recipe:

      LIVE_TEST_MITRA_URL=https://…
      LIVE_TEST_MITRA_TOKEN=…

      just test-federation-live-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/proofs_live_test.exs

  A server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits for the server.

  ⚠️ It acts as a real person: the account posts once (`unlisted`) and our test user mentions it once; both posts are deleted when the test ends.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  @moduletag :live_federation
  # committed data: the tunnelled server and the remote fetching back run outside the test process
  @moduletag db_sandbox: false
  @moduletag capture_log: false

  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Safety.IntegrityProofs
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi

  # {server, whether it signs the activities it delivers with proofs}: the FEP-8b32 implementations with a Mastodon-compatible API to drive them (the FEP lists Mastodon for verification only; Mitra signs "all outgoing activities", not the objects it serves on a fetch, `FEDERATION.md`)
  @servers [{"mitra", true}, {"mastodon", false}]

  # the servers whose inbox refuses a delivery with no valid HTTP signature before reading it, whatever proof it carries: Mastodon (`require_actor_signature!`, 401 "Request not signed", seen 24 October), whose proof check is tested by a forward instead (`inbox_forwarding_live_test.exs`)
  @needs_http_signature ["mastodon"]

  setup do
    Process.put(:federating, true)
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)
    orig_observer = Application.get_env(:activity_pub, :document_observer)
    Application.put_env(:activity_pub, :sign_object_integrity_proofs, true)

    # every document exactly as it arrives at our inbox, and as we send it with the receiver's answer (`ActivityPub.Observer`), which is the only place either can be read: neither is stored as it was
    test_pid = self()

    Application.put_env(:activity_pub, :document_observer, fn document, context ->
      send(test_pid, {:observed, document, context})
    end)

    on_exit(fn ->
      restore_env(:sign_object_integrity_proofs, orig)
      restore_env(:document_observer, orig_observer)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:activity_pub, key)
  defp restore_env(key, value), do: Application.put_env(:activity_pub, key, value)

  for {name, signs?} <- @servers do
    @tag skip:
           MastodonApi.from_env(name) == nil &&
             "set LIVE_TEST_#{String.upcase(name)}_URL and LIVE_TEST_#{String.upcase(name)}_TOKEN in .env"
    @tag timeout: :timer.minutes(20)
    test "#{name}: a post made there, delivered to our user who follows the account, #{if signs?, do: "carries a proof that verifies as its author", else: "carries no proof"}" do
      incoming(unquote(name), unquote(signs?))
    end

    # with our HTTP signature, and without one, when our proof is the only thing the server can trust
    for http_signed? <- [true, false] do
      refused? = !http_signed? and name in @needs_http_signature

      @tag skip:
             MastodonApi.from_env(name) == nil &&
               "set LIVE_TEST_#{String.upcase(name)}_URL and LIVE_TEST_#{String.upcase(name)}_TOKEN in .env"
      @tag timeout: :timer.minutes(20)
      @tag http_signed?: http_signed?
      test "#{name}: our user's post, with our proof on it#{if http_signed?, do: " and our HTTP signature", else: " and no HTTP signature"}, #{if refused?, do: "is refused, as its inbox needs an HTTP signature", else: "reaches the account it mentions"}",
           context do
        if !context[:http_signed?], do: no_http_signatures()
        outgoing(unquote(name), unquote(refused?))
      end
    end
  end

  # deliveries go out as they would to a host we have no actor for: with a digest, and no signature; `:global`, as the deliveries run in Oban's processes
  defp no_http_signatures do
    Repatch.patch(APPublisher, :sign_and_publish_one, [mode: :global], fn _actor, params ->
      APPublisher.publish_one_unsigned(params)
    end)
  end

  defp incoming(name, signs?) do
    api = MastodonApi.from_env(name)
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

    {:ok, account} = MastodonApi.verify_credentials(api) |> ok_or_flunk("reading the account")
    handle = "@#{account["acct"]}@#{URI.parse(api.base).host}"

    # our user follows the account, so what it posts is delivered to us
    me = fake_user!()
    assert {:ok, remote} = Interop.fetch(handle)
    assert {:ok, _} = Interop.follow(handle, as: me)

    Interop.await_incoming([type: "Accept", from: remote.ap_id], seconds: wait) ||
      flunk("#{name} never accepted our user's follow within #{wait}s")

    {:ok, status} =
      MastodonApi.post_status(api, "proof probe #{unique()}", visibility: "unlisted")
      |> ok_or_flunk("posting on #{name}")

    try do
      {create, _context} =
        await_observed(
          fn document, context ->
            context[:source] == :inbox and document["type"] == "Create" and
              ActivityPub.Object.get_ap_id(document["object"]) == status["uri"]
          end,
          wait
        ) || flunk("the Create of #{status["uri"]} never reached our inbox within #{wait}s")

      if signs? do
        assert IntegrityProofs.has_proof?(create),
               "#{name} delivered #{create["id"]} with no proof: #{inspect(create)}"

        assert IntegrityProofs.verify(create) == {:ok, create["actor"]},
               "the proof on #{create["id"]} does not verify as its actor"
      else
        refute IntegrityProofs.has_proof?(create),
               "#{name} now puts proofs on what it delivers: move it to the servers that do"
      end
    after
      cleanup(MastodonApi.delete_status(api, status["id"]), "#{name}'s post")

      with {:ok, followed} <- AdapterUtils.return_pointable(remote, skip_boundary_check: true) do
        Bonfire.Social.Graph.Follows.unfollow(me, followed)
      end
    end
  end

  # the first document the observer saw since the test started for which `match?` is true, with the context it came with (a delivery's answer is in it), waiting up to `seconds`; nil if none
  defp await_observed(match?, seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    do_await_observed(match?, deadline)
  end

  defp do_await_observed(match?, deadline) do
    receive do
      {:observed, document, context} ->
        if match?.(document, context),
          do: {document, context},
          else: do_await_observed(match?, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> nil
    end
  end

  defp outgoing(name, refused?) do
    api = MastodonApi.from_env(name)
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

    {:ok, account} = MastodonApi.verify_credentials(api) |> ok_or_flunk("reading the account")
    handle = "@#{account["acct"]}@#{URI.parse(api.base).host}"
    assert {:ok, _} = Interop.fetch(handle)

    me = fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: "#{handle} a proof probe #{unique()}"}},
        boundary: "public"
      )

    try do
      outgoing = Interop.outgoing_json(post) || flunk("no outgoing JSON for the post")
      post_ap_id = ActivityPub.Object.get_ap_id(outgoing["object"]) || outgoing["id"]
      server_host = URI.parse(api.base).host

      # what we sent the server, as sent (the proof is added last, for each inbox), with its answer
      {sent, delivery} =
        await_observed(
          fn document, context ->
            context[:source] == :delivery and URI.parse(context[:url] || "").host == server_host and
              ActivityPub.Object.get_ap_id(document["object"]) == post_ap_id
          end,
          wait
        ) || flunk("we never delivered #{post_ap_id} to #{name} within #{wait}s")

      assert IntegrityProofs.has_proof?(sent), "our delivery to #{name} carried no proof"

      if refused? do
        assert delivery[:status] == 401,
               "#{name} answered a delivery with no HTTP signature with #{inspect(delivery[:status])}, not 401: it may now accept proofs alone, so move it out of @needs_http_signature: #{inspect(delivery[:body])}"
      else
        assert delivery[:status] in 200..299,
               "#{name} answered our delivery with #{inspect(delivery[:status])}: #{inspect(delivery[:body])}"

        {:ok, me_there} =
          MastodonApi.resolve_account(api, Bonfire.Me.Characters.character_url(me))
          |> ok_or_flunk("#{name} looking up our user")

        assert await(fn -> listed?(api, me_there["id"], post_ap_id) end, wait),
               "our post never reached #{name} within #{wait}s"
      end
    after
      cleanup(Bonfire.Social.Objects.delete(post, current_user: me), "our post")
    end
  end

  # whether the server lists the post with this AP id among the account's statuses; false on a failed read so `await/2` tries again
  defp listed?(api, account_id, ap_id) do
    case MastodonApi.account_statuses(api, account_id) do
      {:ok, statuses} -> Enum.any?(statuses, &(&1["uri"] == ap_id))
      _ -> false
    end
  end

  defp cleanup({:ok, _}, what), do: IO.puts("cleanup: #{what} deleted")

  defp cleanup(other, what),
    do: IO.puts("cleanup FAILED: could not delete #{what}: #{inspect(other)}")

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

  defp unique, do: System.unique_integer([:positive])
end
