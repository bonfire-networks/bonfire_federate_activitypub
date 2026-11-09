defmodule Bonfire.Federate.ActivityPub.LiveFederation.QuoteAcceptLiveTest do
  @moduledoc """
  A quote of one of our posts, made on a real server, that our user accepts (GitHub #1803, "Accepted Quote Post showing as Pending in Mastodon"). The account quotes our user's public post, which needs approval, so the server sends us a `QuoteRequest` and shows the quote as pending. Our user accepts it the way the "Accept quote" button on the notification does, and the server must then show the quote as accepted.

  It needs an account on the server, and a bore tunnel so the server can fetch our post back. The URL and an access token (scopes `read`, `write`, `follow`) go in the git-ignored `.env`, as for `edit_live_test.exs`. `AP_CAPTURE_JSON=1` also records the `QuoteRequest` as it arrived, under `fixtures/captured/<host>/`, for `interop/mastodon_quote_request_ui_test.exs`:

      AP_CAPTURE_JSON=1 BORE_PORT=3 just test-federation-live-DRAGONS \\
        extensions/bonfire_federate_activitypub/test/live_federation/quote_accept_live_test.exs

  A server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits for the server.

  ⚠️ It acts as a real person: the account posts a quote of a test post. The quote and the post are deleted when the test ends.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server fetching back runs outside the test process, so the sandbox transaction would hide our post
  @moduletag db_sandbox: false
  @moduletag capture_log: false

  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
  alias Bonfire.Social.Quotes

  # servers whose API can post a quote (`quoted_status_id`) and shows its `quote.state`
  @servers ~w(mastodon)

  setup do
    Process.put(:federating, true)
    :ok
  end

  for name <- @servers do
    @tag skip:
           MastodonApi.from_env(name) == nil &&
             "set LIVE_TEST_#{String.upcase(name)}_URL and LIVE_TEST_#{String.upcase(name)}_TOKEN in .env"
    @tag timeout: :timer.minutes(20)
    test "#{name}: a quote of our post that our user accepts shows as accepted there" do
      run(unquote(name))
    end
  end

  defp run(name) do
    api = MastodonApi.from_env(name)
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

    author = fake_user!()

    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: author,
               post_attrs: %{post_content: %{html_body: "<p>Bonfire quote probe #{unique()}</p>"}},
               boundary: "public"
             )

    try do
      post_ap_id = Interop.outgoing_json(post)["id"] || flunk("no AP id for the post")
      IO.puts("\n── #{name}: our post is #{post_ap_id} ──\n")

      {:ok, quoted} =
        MastodonApi.resolve_status(api, post_ap_id)
        |> ok_or_flunk("#{name} could not look up #{post_ap_id}")

      since = DateTime.utc_now()

      {:ok, quote_status} =
        MastodonApi.post_status(api, "Quoting a Bonfire post #{unique()}",
          quoted_status_id: quoted["id"]
        )
        |> ok_or_flunk("posting a quote of #{post_ap_id} on #{name}")

      try do
        IO.puts(
          "#{name} made the quote #{quote_status["uri"]}, state: #{inspect(quote_status["quote"]["state"])}"
        )

        # control: the server waits for us, so "accepted" below is our Accept's doing
        assert quote_status["quote"]["state"] == "pending",
               "#{name} did not ask us before quoting: #{inspect(quote_status["quote"])}"

        Interop.await_incoming([type: "QuoteRequest", about: post_ap_id],
          seconds: wait,
          since: since
        ) || flunk("no QuoteRequest from #{name} reached us within #{wait}s")

        quote_post_id =
          Interop.await_pointer(quote_status["uri"], seconds: wait) ||
            flunk("the quoting post #{quote_status["uri"]} was not stored within #{wait}s")

        {:ok, request} =
          Quotes.requested(quote_post_id, post)
          |> ok_or_flunk("control: the quote should be waiting for our user's approval")

        # what the "Accept quote" button on the notification calls (`Bonfire.Social.Objects.LiveHandler`, `quote_accept`)
        {:ok, _} =
          Quotes.accept(id(request), current_user: author)
          |> ok_or_flunk("accepting the quote request")

        accepted? =
          Interop.await(
            fn ->
              match?(
                {:ok, %{"quote" => %{"state" => "accepted"}}},
                MastodonApi.status(api, quote_status["id"])
              )
            end,
            seconds: wait
          )

        IO.puts(
          "after our Accept, #{name} shows the quote as #{if accepted?, do: "accepted", else: "STILL NOT accepted"}"
        )

        assert accepted?,
               "#{name} still does not show the quote as accepted after #{wait}s, so our Accept did not arrive or was not matched to its QuoteRequest; it shows: #{inspect(MastodonApi.status(api, quote_status["id"]))}"
      after
        # the account is a real person's: the quote is deleted, so it leaves their profile
        case MastodonApi.delete_status(api, quote_status["id"]) do
          {:ok, _} ->
            IO.puts("cleanup: #{name} quote deleted")

          other ->
            IO.puts("cleanup FAILED: could not delete the quote on #{name}: #{inspect(other)}")
        end
      end
    after
      Bonfire.Social.Objects.delete(post, current_user: author)
    end
  end

  defp ok_or_flunk({:ok, _} = ok, _what), do: ok
  defp ok_or_flunk(other, what), do: flunk("#{what} failed: #{inspect(other)}")

  defp unique, do: System.unique_integer([:positive])
end
