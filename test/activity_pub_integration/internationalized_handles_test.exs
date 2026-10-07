defmodule Bonfire.Federate.ActivityPub.InternationalizedHandlesTest do
  @moduledoc """
  Remote (and, when enabled, local) handles with non-ASCII characters or dots, e.g. `@josé@mocked.local`, `@你好@你好.local` and `@first.last@mocked.local`. The W3C SocialCG ActivityPub and WebFinger report (3.1.2) says implementers SHOULD support remote usernames containing any valid RFC 7565 characters, and (3.1) that hosts MUST be converted to IDNA A-labels.

  There is one `describe` per column of the SWICG internationalized WebFinger adoption matrix (https://swicg.github.io/activitypub-webfinger/internationalized), so the results map directly to Bonfire's row there.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.DataHelpers

  alias Bonfire.Data.Identity.User
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Tag.TextContent.Formatter
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  # {username, host as typed, actor id}: actor ids use the A-label, as a server on an IDN domain publishes them, and stay ASCII in the path so only the handle is under test
  @remotes [
    {"josé", "mocked.local", "https://mocked.local/users/jose_u"},
    {"你好", "mocked.local", "https://mocked.local/users/nihao"},
    {"first.last", "mocked.local", "https://mocked.local/users/first.last"},
    {"josé", "bücher.local", "https://xn--bcher-kva.local/users/jose_u"},
    {"你好", "你好.local", "https://xn--6qq79v.local/users/nihao"}
  ]

  # hard-coded rather than built with `URI.encode_query`, so a change in how handles get encoded fails here. Only A-label hosts are mocked, so a lookup that sends a U-label host gets a 404.
  @webfinger_urls %{
    "https://mocked.local/.well-known/webfinger?resource=acct%3Ajos%C3%A9%40mocked.local" =>
      "https://mocked.local/users/jose_u",
    "https://mocked.local/.well-known/webfinger?resource=acct%3A%E4%BD%A0%E5%A5%BD%40mocked.local" =>
      "https://mocked.local/users/nihao",
    "https://mocked.local/.well-known/webfinger?resource=acct%3Afirst.last%40mocked.local" =>
      "https://mocked.local/users/first.last",
    "https://xn--bcher-kva.local/.well-known/webfinger?resource=acct%3Ajos%C3%A9%40xn--bcher-kva.local" =>
      "https://xn--bcher-kva.local/users/jose_u",
    "https://xn--6qq79v.local/.well-known/webfinger?resource=acct%3A%E4%BD%A0%E5%A5%BD%40xn--6qq79v.local" =>
      "https://xn--6qq79v.local/users/nihao"
  }

  setup do
    Process.put(:federating, true)

    # `.local` is not a known TLD, and posts are processed with TLD validation unless this is set (read at runtime by `Bonfire.Tag.TextContent.Process`). Safe to set since this module is `async: false`, so it runs after all async modules.
    previous_skip = System.get_env("SKIP_LINK_DOMAINS_VALIDATION")
    System.put_env("SKIP_LINK_DOMAINS_VALIDATION", "1")

    on_exit(fn ->
      if previous_skip,
        do: System.put_env("SKIP_LINK_DOMAINS_VALIDATION", previous_skip),
        else: System.delete_env("SKIP_LINK_DOMAINS_VALIDATION")
    end)

    test_pid = self()

    # plus an ASCII `jose` next to `josé`, for the hash collision check
    actors =
      @remotes
      |> Map.new(fn {username, _host, id} -> {id, username} end)
      |> Map.put("https://mocked.local/users/jose", "jose")

    mock_global(fn
      %{method: :post, url: url, body: body} ->
        send(test_pid, {:delivered, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: url} ->
        cond do
          actor_id = @webfinger_urls[url] ->
            json(Simulate.webfingered(actors[actor_id], actor_id))

          username = actors[url] ->
            json(Simulate.actor_json(url, username))

          String.ends_with?(url, ["/followers", "/following", "/outbox"]) ->
            json(%{})

          true ->
            %Tesla.Env{status: 404, body: ""}
        end
    end)

    :ok
  end

  defp remote_user!(handle) do
    assert {:ok, user} = AdapterUtils.get_by_url_ap_id_or_username(handle)
    user
  end

  describe "Link: non-ASCII and dotted handles are linkified in in-band mentions" do
    for {username, host, _actor_id} <- @remotes do
      test "@#{username}@#{host}" do
        handle = "#{unquote(username)}@#{unquote(host)}"

        # called directly, so the `.local` TLD needs skipping here (the env var above only applies to `Process`)
        assert {linkified, [{display_name, %{id: mentioned_id}}], _, _} =
                 Formatter.linkify("hi @#{handle} there",
                   safe_mention: false,
                   content_type: "text/markdown",
                   validate_tld: false
                 )

        assert mentioned_id == id(remote_user!(handle))
        assert display_name =~ unquote(username)
        assert linkified =~ "hi [#{display_name}]("
      end
    end
  end

  describe "Send: local users can send activities to a remote account with a non-ASCII handle" do
    for {username, host, actor_id} <- @remotes do
      test "a post typed with @#{username}@#{host} is addressed to that actor" do
        me = fake_user!()

        assert {:ok, post} =
                 Posts.publish(
                   current_user: me,
                   post_attrs: %{
                     post_content: %{
                       html_body: "hey @#{unquote(username)}@#{unquote(host)} hi"
                     }
                   },
                   boundary: "mentions"
                 )

        assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

        assert unquote(actor_id) in (List.wrap(ap_activity.data["to"]) ++
                                       List.wrap(ap_activity.data["cc"]))

        mention =
          Enum.find(
            ap_activity.object.data["tag"] || [],
            &(&1["type"] == "Mention" and &1["href"] == unquote(actor_id))
          )

        assert mention, "Expected a Mention tag for #{unquote(actor_id)}"

        # the remote username is stored with the host of the actor id, so the canonical (A-label) host is what goes out
        assert mention["name"] ==
                 "@#{unquote(username)}@#{URI.parse(unquote(actor_id)).host}"
      end
    end

    test "following a remote non-ASCII handle found by lookup sends a Follow" do
      me = fake_user!()
      followed = remote_user!("josé@mocked.local")

      assert {:ok, follow} = Follows.follow(me, followed)
      assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)
      assert Follows.requested?(me, followed)
    end
  end

  describe "Search: the search interface can discover an actor with a non-ASCII handle" do
    for {username, host, actor_id} <- @remotes do
      test "looking up @#{username}@#{host}" do
        user = remote_user!("@#{unquote(username)}@#{unquote(host)}")

        # stored with the host of the actor id, i.e. the A-label for an IDN
        assert user.character.username ==
                 "#{unquote(username)}@#{URI.parse(unquote(actor_id)).host}"
      end

      test "the search page finds @#{username}@#{host}" do
        account = fake_account!()
        me = fake_user!(account)

        conn(user: me, account: account)
        |> visit("/search?s=" <> URI.encode_www_form("@#{unquote(username)}@#{unquote(host)}"))
        |> wait_async()
        |> assert_has("[data-role=search_people_strip]", text: unquote(username))
      end

      test "a known @#{username}@#{host} is found by a DB search for #{username}" do
        user = remote_user!("#{unquote(username)}@#{unquote(host)}")

        assert id(user) in Enum.map(
                 Bonfire.Search.DB.search_by_type(unquote(username), User,
                   skip_boundary_check: true
                 ),
                 &id/1
               )

        assert id(user) in Enum.map(
                 Bonfire.Me.Users.search(unquote(username), db_merge: true),
                 &id/1
               )
      end
    end

    for {name, query} <- [{"José Núñez", "núñez"}, {"你好世界", "你好"}] do
      test "a DB search for #{query} finds a user named #{name}" do
        user = fake_user!(fake_account!(), %{name: unquote(name)})

        assert id(user) in Enum.map(
                 Bonfire.Search.DB.search_by_type(unquote(query), User,
                   skip_boundary_check: true
                 ),
                 &id/1
               )
      end
    end
  end

  describe "Username: local users can have a non-ASCII username, when enabled with UNICODE_USERNAMES" do
    setup do
      Process.put([:bonfire_me, Bonfire.Me.Characters, :unicode_usernames], true)
      :ok
    end

    defp local_user!(username) do
      # the profile name is set apart, since names have their own minimum length
      user =
        fake_user!(fake_account!(), %{username: username, name: "Test #{username}"})

      assert user.character.username == username
      user
    end

    # plainascii is the control: the same page and assertion with an ASCII username
    for username <- ["plainascii", "josé", "你好"] do
      test "the profile page of @#{username} works" do
        user = local_user!(unquote(username))
        account = fake_account!()
        me = fake_user!(account)

        conn(user: me, account: account)
        |> visit("/@" <> unquote(username))
        |> wait_async()
        |> assert_has("[data-id=profile_hero]", text: user.profile.name)
      end
    end

    for username <- ["josé", "你好"] do
      test "WebFinger serves acct:#{username} for this instance" do
        user = local_user!(unquote(username))
        host = ActivityPub.Federator.WebFinger.local_hostname()

        assert {:ok, %{"subject" => subject, "links" => links}} =
                 ActivityPub.Federator.WebFinger.output("acct:#{unquote(username)}@#{host}")

        assert subject == "acct:#{unquote(username)}@#{host}"
        actor = ActivityPub.Actor.get_cached!(pointer: user.id)
        assert Enum.any?(links, &(&1["rel"] == "self" and &1["href"] == actor.ap_id))
      end

      test "a local post mentioning @#{username} mentions them" do
        mentioned = local_user!(unquote(username))

        assert {:ok, post} =
                 Posts.publish(
                   current_user: fake_user!(),
                   post_attrs: %{post_content: %{html_body: "hi @#{unquote(username)} there"}},
                   boundary: "mentions"
                 )

        assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
                 current_user: mentioned
               )
      end
    end
  end

  describe "Receive: local users can receive activities from a remote account with a non-ASCII handle" do
    for {username, host, actor_id} <- @remotes do
      test "a Note from @#{username}@#{host} mentioning a local user notifies them" do
        {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: unquote(actor_id))
        recipient = fake_user!()
        recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

        # the object lives on the actor's own origin, so it can't be rejected for a host mismatch
        origin = "https://" <> URI.parse(unquote(actor_id)).host

        params =
          remote_activity_json_with_mentions(
            actor,
            [recipient_actor, ActivityPub.Config.public_uri()],
            %{"id" => origin <> "/pub/" <> Needle.UID.generate()}
          )

        {:ok, activity} = ActivityPub.create(params)

        assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

        assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
                 current_user: recipient
               )
      end
    end

    # remote characters keep a hash of their raw username, so no confusable folding may apply to them
    test "remote users jose and josé on the same host can both be stored" do
      for {username, id} <- [
            {"jose", "https://mocked.local/users/jose"},
            {"josé", "https://mocked.local/users/jose_u"}
          ] do
        assert {:ok, user} =
                 Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(
                   Simulate.actor_json(id, username)
                 )

        assert user.character.username == "#{username}@mocked.local"
      end
    end
  end
end
