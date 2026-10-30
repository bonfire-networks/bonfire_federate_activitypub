if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.GroupRemoteEditLiveTest do
    @moduledoc """
    An edit of a post in one of our groups, by its author on another instance, as the group's follower on a real server sees it: three servers. Our instance hosts the group, the dance's other instance has the member who posts and then edits, and a real server's account follows the group.

    The edit reaches the follower only through the group: the member's instance sends its `Update` to the group, which checks the author's FEP-8b32 proof and announces it unchanged (`Announce{Update}`, FEP-1b12). The follower does not follow the member, so a server that shows the new text applied a relayed `Update` of someone else's post, on the strength of the author's proof or of a fetch of the post. `group_account_live_test.exs` (T2b) is the two-server case, where the author is on the group's own instance and our `Update` is the one the server gets.

    Both dance instances must be reachable from the real server (it fetches the post and the member's key from the other instance), so it runs through the recipe that tunnels both:

        just test-federation-live-dance-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/group_remote_edit_live_test.exs

    The accounts are the `.env` ones of `group_account_live_test.exs`; a server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits.

    ⚠️ It acts as a real person: the account follows a test group here, and unfollows when the test ends.
    """
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    # not `:test_instance`: it acts as real people, so it runs through the live recipe only, never in `--only test_instance` dance runs
    @moduletag :live_federation
    @moduletag capture_log: false

    import Bonfire.Federate.ActivityPub.SharedDataDanceCase

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.Testing.Interop
    alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
    alias Bonfire.Federate.ActivityPub.Testing.Tester

    @servers ~w(mastodon gotosocial akkoma pleroma sharkey firefish mitra)

    setup context do
      Process.put(:federating, true)
      clean_slate(context)
    end

    for server <- @servers do
      @tag server: server
      @tag skip:
             MastodonApi.from_env(server) == nil &&
               "set LIVE_TEST_#{String.upcase(server)}_URL and LIVE_TEST_#{String.upcase(server)}_TOKEN in .env"
      @tag timeout: :timer.minutes(40)
      test "#{server}: an edit of a post in our group, by its author on the other instance, shows on the follower's timeline",
           context do
        run(context)
      end
    end

    defp run(context) do
      name = context[:server]
      api = MastodonApi.from_env(name)
      wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

      group = Interop.Groups.hosted_group(context[:local][:user])
      group_url = group[:canonical_url]

      IO.puts("\n── #{name}: our group is #{group_url} ──\n")

      follower = Tester.new({Tester.NomadTester, {:mastodon_api, name}}, context)
      assert {:ok, follower} = Tester.follow(follower, group_url)

      try do
        {:ok, account} =
          MastodonApi.resolve_account(api, group_url)
          |> ok_or_flunk("#{name} could not look up #{group_url}")

        assert Interop.await(
                 fn ->
                   match?({:ok, %{"following" => true}}, MastodonApi.relationship(api, account["id"]))
                 end,
                 seconds: wait
               ),
               "#{name} never showed the group as followed within #{wait}s, so our Accept did not arrive or was not understood"

        # the member joins the group from the other instance and posts in it there
        %{post_url: post_url, remote_post_id: remote_post_id} =
          Interop.Groups.remote_member_post_in_group!(
            context,
            "<p>Bonfire remote edit probe #{unique()}</p>",
            group
          )

        # control: the post itself reached the follower through the group, so a missing edit below is the edit's
        entries =
          Interop.await(fn -> MastodonApi.entries_showing(api, post_url, group_url) end,
            seconds: wait
          )

        assert entries not in [nil, []],
               "the member's post never appeared on #{name}'s home timeline within #{wait}s, which held: #{MastodonApi.timeline_dump(api)}"

        edited_text = "edited by its author on the other instance #{unique()}"

        TestInstanceRepo.apply(fn ->
          assert {:ok, _} =
                   Bonfire.Social.PostContents.edit(context[:remote][:user], remote_post_id, %{
                     html_body: "<p>Bonfire remote edit probe, #{edited_text}</p>"
                   })
        end)

        edit_shown? =
          Interop.await(fn -> MastodonApi.shows_text?(api, post_url, group_url, edited_text) end,
            seconds: wait
          )

        IO.puts(
          "after the edit, #{name} #{if edit_shown?, do: "shows the new text", else: "STILL SHOWS the old text"}"
        )

        assert edit_shown?,
               "#{name} still shows the old text of the post after #{wait}s, so the group's relayed `Update` did not arrive or was not applied; the timeline held: #{MastodonApi.timeline_dump(api)}"
      after
        # the account is a real person's, so say what happened to the follow
        case Tester.unfollow(follower, group_url) do
          :ok -> :ok
          {:ok, _} -> IO.puts("cleanup: #{name} unfollowed #{group_url}")
          other -> IO.puts("cleanup FAILED: could not unfollow #{group_url} on #{name}: #{inspect(other)}")
        end
      end
    end

    defp ok_or_flunk({:ok, _} = ok, _what), do: ok
    defp ok_or_flunk(other, what), do: flunk("#{what} failed: #{inspect(other)}")

    defp unique, do: System.unique_integer([:positive])
  end
end
