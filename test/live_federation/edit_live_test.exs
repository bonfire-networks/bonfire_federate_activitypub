defmodule Bonfire.Federate.ActivityPub.LiveFederation.EditLiveTest do
  @moduledoc """
  An edit of an ordinary post (not in a group), as a follower on a real server sees it: the account follows our user, our user posts, edits it, and the account's home timeline shows the new text. The author's `Update` goes to the follower directly, signed (HTTP signature, and the FEP-8b32 proof on the `Update` and on the object, as the stored signed original is renewed on every edit). `group_account_live_test.exs` (T2b) is the same for a post in a group.

  It needs an account on the server, and a bore tunnel so the server can fetch our user back. The URL and an access token (scopes `read`, `write`, `follow`) go in the git-ignored `.env`, one pair per server, as for `group_account_live_test.exs`:

      BORE_PORT=3 just test-federation-live-DRAGONS \\
        extensions/bonfire_federate_activitypub/test/live_federation/edit_live_test.exs

  A server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits for the server.

  ⚠️ It acts as a real person: the account follows a test user and sees one post of theirs. The post is deleted and the user unfollowed when the test ends.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server fetching back runs outside the test process, so the sandbox transaction would hide our user
  @moduletag db_sandbox: false
  @moduletag capture_log: false

  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi

  @servers ~w(mastodon gotosocial akkoma pleroma sharkey firefish mitra)

  setup do
    Process.put(:federating, true)
    :ok
  end

  for name <- @servers do
    @tag skip:
           MastodonApi.from_env(name) == nil &&
             "set LIVE_TEST_#{String.upcase(name)}_URL and LIVE_TEST_#{String.upcase(name)}_TOKEN in .env"
    @tag timeout: :timer.minutes(20)
    test "#{name}: a follower sees the new text of a post after its author edits it" do
      run(unquote(name))
    end
  end

  defp run(name) do
    api = MastodonApi.from_env(name)
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

    author = fake_user!()
    {:ok, %{ap_id: author_url}} = ActivityPub.Actor.get_cached(pointer: author)

    IO.puts("\n── #{name}: our user is #{author_url} ──\n")

    {:ok, account} =
      MastodonApi.resolve_account(api, author_url)
      |> ok_or_flunk("#{name} could not look up #{author_url}")

    {:ok, _} = MastodonApi.follow(api, account["id"]) |> ok_or_flunk("following our user")

    try do
      Interop.await_incoming([type: "Follow", about: author_url], seconds: wait) ||
        flunk("no Follow from #{name} reached us within #{wait}s")

      assert Interop.await(
               fn ->
                 match?({:ok, %{"following" => true}}, MastodonApi.relationship(api, account["id"]))
               end,
               seconds: wait
             ),
             "#{name} never showed our user as followed within #{wait}s, so our Accept did not arrive or was not understood"

      probe = "Bonfire edit probe #{unique()}"

      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: author,
                 post_attrs: %{post_content: %{html_body: "<p>#{probe}</p>"}},
                 boundary: "public"
               )

      try do
        post_ap_id = Interop.outgoing_json(post)["id"] || flunk("no AP id for the post")

        # control: the post itself reached the follower, so a missing edit below is the edit's
        assert Interop.await(fn -> MastodonApi.shows_status_text?(api, post_ap_id, probe) end,
                 seconds: wait
               ),
               "the post never appeared on #{name}'s home timeline within #{wait}s, which held: #{MastodonApi.timeline_dump(api)}"

        edited_text = "edited by its author #{unique()}"

        assert {:ok, _} =
                 Bonfire.Social.PostContents.edit(author, id(post), %{
                   html_body: "<p>#{probe}, #{edited_text}</p>"
                 })

        edit_shown? =
          Interop.await(fn -> MastodonApi.shows_status_text?(api, post_ap_id, edited_text) end,
            seconds: wait
          )

        IO.puts(
          "after the edit, #{name} #{if edit_shown?, do: "shows the new text", else: "STILL SHOWS the old text"}"
        )

        assert edit_shown?,
               "#{name} still shows the old text of the post after #{wait}s, so the author's `Update` did not arrive or was not applied; the timeline held: #{MastodonApi.timeline_dump(api)}"
      after
        # the account is a real person's: the post is deleted, so it leaves their timeline
        Bonfire.Social.Objects.delete(post, current_user: author)
      end
    after
      case MastodonApi.unfollow(api, account["id"]) do
        {:ok, relationship} ->
          IO.puts("cleanup: #{name} unfollowed, following: #{inspect(relationship["following"])}")

        other ->
          IO.puts("cleanup FAILED: could not unfollow #{author_url} on #{name}: #{inspect(other)}")
      end
    end
  end

  defp ok_or_flunk({:ok, _} = ok, _what), do: ok
  defp ok_or_flunk(other, what), do: flunk("#{what} failed: #{inspect(other)}")

  defp unique, do: System.unique_integer([:positive])
end
