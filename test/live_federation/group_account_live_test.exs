defmodule Bonfire.Federate.ActivityPub.LiveFederation.GroupAccountLiveTest do
  @moduledoc """
  What a person on a microblog server sees of one of OUR groups: the follow works, a post in the group arrives on their timeline as a boost BY the group (or, on a server that files a relayed post under the group itself, as its author's post marked as in the group), a reply from them is filed in the group, and a deletion is followed. The result is read from the account's own timeline through its Mastodon-compatible API, which is the only place the Mastodon, GoToSocial, Akkoma, Pleroma, Sharkey, Firefish and Mitra rows of the interop checklist can be answered (`group_live_test.exs` can only tell whether a delivery was accepted, not what the server made of it).

  It needs an account on the server, and a bore tunnel so the server can fetch our group back. Put the URL and an access token (scopes `read`, `write`, `follow`) in the git-ignored `.env`, one pair per server, and run it through the tunnel recipe:

      LIVE_TEST_MASTODON_URL=https://mastodon.social
      LIVE_TEST_MASTODON_TOKEN=…

      BORE_PORT=3 just test-federation-live-DRAGONS \\
        extensions/bonfire_federate_activitypub/test/live_federation/group_account_live_test.exs

  A server whose two variables are not set is skipped. `LIVE_TEST_AUTHOR` (a username) keeps the group's author the same across runs, for servers that reject notes from remote accounts they saw for the first time minutes ago (Akkoma's `RejectNewlyCreatedAccountNotesPolicy`); the first run still meets that filter, later runs do not. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits for the server, which can be minutes on a large one.

  ⚠️ It acts as a real person: the account follows our test group and posts one reply, which the account's followers can see. The reply is `unlisted`, and it is deleted again, and the group unfollowed, when the test ends.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server and the remote fetching back run outside the test process, so the sandbox transaction would hide our group
  @moduletag db_sandbox: false
  # a test that waits on a remote needs to show what is arriving WHILE it waits
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
    @tag timeout: :timer.minutes(40)
    test "#{name}: an account follows our group, sees its posts as the group's boosts, replies, and sees a deletion" do
      run(unquote(name))
    end
  end

  defp run(name) do
    api = MastodonApi.from_env(name)
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

    # a named author is created on the first run and found again on later ones (`fake_user!/1` falls back to the existing username), so a server that filters brand-new remote accounts sees an old one
    creator =
      case System.get_env("LIVE_TEST_AUTHOR") do
        nil -> fake_user!()
        username -> fake_user!(username)
      end

    group = Interop.Groups.hosted_group(creator)
    group_url = group[:canonical_url]

    IO.puts("\n── #{name}: our group is #{group_url} ──\n")

    # T1: the account can find and follow the group, which proves the server fetched our actor with a signed request
    {:ok, account} =
      MastodonApi.resolve_account(api, group_url) |> ok_or_flunk("#{name} could not look up #{group_url}")

    IO.puts("#{name} sees the group as #{account["acct"]}, `group: #{inspect(account["group"])}`")

    {:ok, _} = MastodonApi.follow(api, account["id"]) |> ok_or_flunk("following the group")

    try do
      follow =
        Interop.await_incoming([type: "Follow", about: group_url], seconds: wait) ||
          flunk("no Follow from #{name} reached us within #{wait}s")

      # the account as it acts on the wire, to recognise its reply later
      account_actor = ActivityPub.Object.get_ap_id(follow.data["actor"])

      assert await(fn -> following?(api, account["id"]) end, wait),
             "#{name} never showed the group as followed within #{wait}s, so our Accept did not arrive or was not understood"

      # T2: a post in the group is on the timeline once, as a boost by the group or, on a server that files a relayed post under the group itself, as its author's post marked as in the group
      post = publish(creator, group, "<p>Bonfire group relay probe #{unique()}</p>")
      post_ap_id = Interop.outgoing_json(post)["id"] || flunk("no AP id for the post")

      entries = await(fn -> entries_showing(api, post_ap_id, group_url) end, wait)

      assert entries != nil and entries != [],
             "the post never appeared on #{name}'s home timeline within #{wait}s, which held: #{timeline_dump(api)}"

      assert length(entries) == 1,
             "the post appeared #{length(entries)} times on #{name}'s timeline, but the group's two announce copies should be one entry: #{inspect(Enum.map(entries, & &1["id"]))}"

      [entry] = entries

      if entry["reblog"] do
        IO.puts("boost by #{inspect(get_in(entry, ["account", "acct"]))} of #{get_in(entry, ["reblog", "uri"])}")

        assert get_in(entry, ["account", "acct"]) =~ account["acct"] |> String.split("@") |> hd(),
               "the boost is not by the group's account: #{inspect(get_in(entry, ["account", "acct"]))}"
      else
        IO.puts("#{name} shows the post as #{inspect(get_in(entry, ["account", "acct"]))}'s, filed in group #{inspect(get_in(entry, ["group", "acct"]))}, with no boost")
      end

      # T3: a titled post, and how the server shows its title and body
      titled = publish(creator, group, "<p>The body of the thread #{unique()}</p>", "A live interop thread")
      titled_ap_id = Interop.outgoing_json(titled)["id"] || flunk("no AP id for the titled post")

      titled_entries = await(fn -> entries_showing(api, titled_ap_id, group_url) end, wait)

      assert titled_entries != nil and titled_entries != [],
             "the titled post never appeared on #{name}'s timeline within #{wait}s, which held: #{timeline_dump(api)}"

      shown = shown_post(hd(titled_entries))

      IO.puts("""
      titled post as #{name} shows it:
        type of our object: #{inspect(Interop.outgoing_json(titled)["type"])}
        spoiler_text:       #{inspect(shown["spoiler_text"])}
        sensitive:          #{inspect(shown["sensitive"])}
        content:            #{inspect(String.slice(shown["content"] || "", 0, 300))}
      """)

      assert (shown["content"] || "") <> (shown["spoiler_text"] || "") =~ "A live interop thread",
             "#{name} shows neither the title nor a link to it: #{inspect(shown["content"])}"

      # T5: a reply from the account is filed in the group
      original_id = shown_post(entry)["id"]

      {:ok, reply} =
        MastodonApi.post_status(api, "a reply from #{name} #{unique()}",
          in_reply_to_id: original_id,
          visibility: "unlisted"
        )
        |> ok_or_flunk("replying from #{name}")

      try do
        incoming =
          Interop.await_incoming([type: "Create", from: account_actor], seconds: wait) ||
            flunk("the reply from #{name} never reached us within #{wait}s")

        object_id = ActivityPub.Object.get_ap_id(incoming.data["object"])

        pointer_id =
          Interop.await_pointer(object_id, seconds: 60) ||
            flunk("#{object_id} was stored but never became a local object")

        assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, pointer_id,
                 by: group[:category],
                 current_user: creator
               ),
               "the reply arrived but is not in the group's feed"
      after
        case MastodonApi.delete_status(api, reply["id"]) do
          {:ok, _} -> IO.puts("cleanup: #{name} reply deleted")
          other -> IO.puts("cleanup FAILED: could not delete the reply on #{name}: #{inspect(other)}")
        end
      end

      # T6: deleting the titled post takes it (its boost, or the post filed in the group) off the timeline
      assert {:ok, _} = Bonfire.Social.Objects.delete(titled, current_user: creator)

      gone? = await(fn -> entries_showing(api, titled_ap_id, group_url) == [] end, div(wait, 2))

      IO.puts(
        "after the delete, #{name} #{if gone?, do: "removed the post", else: "STILL SHOWS the post"}"
      )

      assert gone?, "#{name} still shows the deleted post after #{div(wait, 2)}s"

      # T7: the posts themselves leave the author's profile, which only a `Delete` from the author does (`Activity::Delete` takes `Status.find_by(uri:, account: author)`). The untitled probe is deleted now too, so a run leaves nothing of its own on the server.
      author_id = get_in(shown_post(entry), ["account", "id"])
      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: creator)

      profile_clean? =
        await(
          fn -> not on_profile?(api, author_id, [titled_ap_id, post_ap_id]) end,
          div(wait, 2)
        )

      IO.puts(
        "after deleting both, #{name} #{if profile_clean?, do: "no longer lists them on the author's profile", else: "STILL LISTS them on the author's profile"}"
      )

      assert profile_clean?,
             "#{name} still lists a deleted post on the author's profile after #{div(wait, 2)}s, because the author's Delete never reached it"
    after
      # the account is a real person's, so leaving it following our test group is not an option: say what happened, and check
      case MastodonApi.unfollow(api, account["id"]) do
        {:ok, relationship} ->
          IO.puts("cleanup: #{name} unfollowed, following: #{inspect(relationship["following"])}")

        other ->
          IO.puts("cleanup FAILED: could not unfollow #{group_url} on #{name}: #{inspect(other)}")
      end

      if following?(api, account["id"]),
        do: IO.puts("cleanup FAILED: #{name} still shows the account as following #{group_url}, unfollow it by hand")
    end
  end

  defp publish(creator, group, html, title \\ nil) do
    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{name: title, html_body: html}},
               publish_in: uid(group[:category]),
               boundary: "public"
             )

    post
  end

  defp following?(api, account_id) do
    match?({:ok, %{"following" => true}}, MastodonApi.relationship(api, account_id))
  end

  # the home-timeline entries that show the post with this AP id as a post in the group (a boost of it, or the post itself marked as in the group), [] when it is not there; nil on a failed read so `await/2` tries again
  defp entries_showing(api, ap_id, group_url) do
    case MastodonApi.home_timeline(api, limit: 40) do
      {:ok, statuses} -> Enum.filter(statuses, &MastodonApi.shows_post?(&1, ap_id, group_url))
      _ -> nil
    end
  end

  # the post itself: inside the boost when the entry is one, else the entry
  defp shown_post(entry), do: entry["reblog"] || entry

  # what the home timeline holds, for a failure message: who posted each status, its URI, what it boosts, and the group it is filed in; a server that shows the post some other way than as a boost shows up here
  defp timeline_dump(api) do
    case MastodonApi.home_timeline(api, limit: 40) do
      {:ok, statuses} ->
        statuses
        |> Enum.map(
          &%{
            by: get_in(&1, ["account", "acct"]),
            uri: &1["uri"],
            boosts: get_in(&1, ["reblog", "uri"]),
            group: get_in(&1, ["group", "acct"])
          }
        )
        |> inspect(limit: :infinity)

      other ->
        "(could not read the timeline: #{inspect(other)})"
    end
  end

  # whether any of these posts is still listed on the author's profile; a failed read counts as "still there", so a flaky answer never reads as a clean profile
  defp on_profile?(api, author_id, ap_ids) do
    case MastodonApi.account_statuses(api, author_id) do
      {:ok, statuses} -> Enum.any?(statuses, &(&1["uri"] in ap_ids))
      _ -> true
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

  defp unique, do: System.unique_integer([:positive])
end
