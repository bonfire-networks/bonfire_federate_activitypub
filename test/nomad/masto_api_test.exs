defmodule Bonfire.Federate.ActivityPub.Nomad.MastoAPITest do
  @moduledoc """
  `Nomad.MastoAPI`: a remote user, with a token for their server's Mastodon API in the opts (`mastodon_api_token`), reads through that API (through Hunter): `resolve` searches with `resolve=true`, and `find_post` gives the status as the API gives it. Their server is stubbed (`Req.Test`, through Hunter's `req_options`), with the shapes Mastodon answers with.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.Nomad
  alias Bonfire.Federate.ActivityPub.Simulate

  @post_url "https://bonfire.local/pub/objects/01POST"
  @token "a-token"

  # a status as Mastodon's API gives it, trimmed to what `find_post` reads and what Hunter needs to decode it
  @status %{
    "id" => "110",
    "uri" => @post_url,
    "url" => @post_url,
    "content" =>
      "<p>a post with <a href=\"https://bonfire.local/hashtag/elixir\">#elixir</a></p>",
    "sensitive" => false,
    "tags" => [%{"name" => "elixir", "url" => "https://mocked.local/tags/elixir"}],
    "media_attachments" => [
      %{
        "id" => "7",
        "type" => "image",
        "url" => "https://mocked.local/media/beach.png",
        "description" => "A sunset over the sea"
      }
    ],
    "account" => %{"id" => "1", "acct" => "alice@bonfire.local"}
  }

  setup do
    # the remote user's actor and images, as `Simulate.fake_remote_user/0` fetches them
    Tesla.Mock.mock(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)

    orig = Application.get_env(:hunter, :req_options)
    Application.put_env(:hunter, :req_options, plug: {Req.Test, Nomad.MastoAPI})

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:hunter, :req_options),
        else: Application.put_env(:hunter, :req_options, orig)
    end)

    {:ok, remote} = Simulate.fake_remote_user()
    {:ok, remote: remote}
  end

  # their server: a search with `resolve=true` for the post's URL finds the status, with the token
  defp stub_server(test_pid) do
    Req.Test.stub(Nomad.MastoAPI, fn conn ->
      send(
        test_pid,
        {:request, conn.host, conn.request_path, conn.query_string,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      case conn.request_path do
        "/api/v2/search" ->
          Req.Test.json(conn, %{"accounts" => [], "statuses" => [@status], "hashtags" => []})
      end
    end)
  end

  test "resolve searches their server, resolving the URI, with their token", %{remote: remote} do
    stub_server(self())

    assert {:ok, %{uri: @post_url}} =
             Nomad.resolve(@post_url, current_user: remote, mastodon_api_token: @token)

    assert_received {:request, "mocked.local", "/api/v2/search", query, ["Bearer " <> @token]}
    assert URI.decode_query(query)["resolve"] == "true"
    assert URI.decode_query(query)["q"] == @post_url
  end

  test "find_post gives the status, as the API gives it", %{remote: remote} do
    stub_server(self())

    assert {:ok,
            %Hunter.Status{
              uri: @post_url,
              content: content,
              tags: [%Hunter.Tag{name: "elixir"}],
              media_attachments: [%Hunter.Attachment{description: "A sunset over the sea"}],
              sensitive: false
            }} = Nomad.find_post(@post_url, current_user: remote, mastodon_api_token: @token)

    assert content =~ "a post with"
  end

  test "an error from their server is an error tuple, not a raise", %{remote: remote} do
    Req.Test.stub(Nomad.MastoAPI, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "The access token is invalid"})
    end)

    assert {:error, {:mastodon_api, _reason}} =
             Nomad.find_post(@post_url, current_user: remote, mastodon_api_token: @token)
  end

  test "Follows.nomad(:follow, ...) follows one of our users through their server's API, finding our user there first",
       %{remote: remote} do
    ours = fake_user!()
    ours_url = Bonfire.Common.URIs.canonical_url(ours)
    test_pid = self()

    Req.Test.stub(Nomad.MastoAPI, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string})

      case {conn.method, conn.request_path} do
        {"GET", "/api/v2/search"} ->
          Req.Test.json(conn, %{
            "accounts" => [%{"id" => "42", "acct" => "#{ours.character.username}@bonfire.local"}],
            "statuses" => [],
            "hashtags" => []
          })

        {"POST", "/api/v1/accounts/42/follow"} ->
          Req.Test.json(conn, %{"id" => "42", "following" => true})
      end
    end)

    assert {:ok, _relationship} =
             Bonfire.Social.Graph.Follows.nomad(:follow, remote, ours,
               current_user: remote,
               mastodon_api_token: @token
             )

    assert_received {:request, "GET", "/api/v2/search", query}
    assert URI.decode_query(query)["q"] == ours_url
    assert URI.decode_query(query)["resolve"] == "true"
    assert_received {:request, "POST", "/api/v1/accounts/42/follow", _}

    # nothing was done here as them
    refute Bonfire.Social.Graph.Follows.following?(remote, ours)
  end

  test "Posts.nomad(:publish, ...) posts a status through their server's API, as text, and publishes nothing here as them",
       %{remote: remote} do
    test_pid = self()

    Req.Test.stub(Nomad.MastoAPI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, @status)
    end)

    assert {:ok, %Hunter.Status{uri: @post_url}} =
             Bonfire.Posts.nomad(:publish,
               current_user: remote,
               mastodon_api_token: @token,
               post_attrs: %{post_content: %{html_body: "<p>a post with #elixir</p>"}},
               boundary: "public"
             )

    assert_received {:request, "POST", "/api/v1/statuses",
                     %{"status" => "a post with #elixir", "visibility" => "public"}}

    # nothing was published here as them
    assert Bonfire.Posts.list_by(remote, current_user: remote) |> e(:edges, []) == []
  end

  test "without a token, a remote user's follow is refused, and nothing is done here as them", %{
    remote: remote
  } do
    ours = fake_user!()

    assert {:error, {:not_supported, :follow, :remote}} =
             Bonfire.Social.Graph.Follows.nomad(:follow, remote, ours, current_user: remote)

    refute Bonfire.Social.Graph.Follows.following?(remote, ours)
  end

  test "without a token, a remote user still has no transport", %{remote: remote} do
    assert {:error, {:not_supported, :find_post, :remote}} =
             Nomad.find_post(@post_url, current_user: remote)
  end
end
