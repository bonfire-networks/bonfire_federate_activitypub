defmodule Bonfire.Federate.ActivityPub.MastodonApiClientTest do
  @moduledoc """
  The small client the live account tests use to act as a person on a remote server that speaks the Mastodon-compatible API (Mastodon, GoToSocial, Akkoma, Pleroma, Sharkey, Firefish, Mitra): look up an account, follow it, read the home timeline, post, delete. It is checked here against a mocked HTTP layer, for the request it makes and what it does with an answer, so that a live run's failure is about the remote and not about this client.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi

  @base "https://social.example"

  defp client, do: MastodonApi.new(@base, "secret-token")

  # the request as the mock sees it: the method, the full URL with its query, the headers, and the form fields sent
  defp seen(env) do
    query = env.query |> List.wrap() |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    %{
      method: env.method,
      url: env.url,
      query: query,
      auth:
        Enum.find_value(env.headers, fn {k, v} ->
          if String.downcase(k) == "authorization", do: v
        end),
      body: env.body
    }
  end

  test "it refuses to be built without a URL and a token" do
    assert_raise ArgumentError, fn -> MastodonApi.new("", "t") end
    assert_raise ArgumentError, fn -> MastodonApi.new(@base, "") end
    assert_raise ArgumentError, fn -> MastodonApi.new(@base, nil) end
  end

  test "it is configured from LIVE_TEST_<NAME>_URL and _TOKEN, and is absent when either is unset" do
    System.put_env("LIVE_TEST_UNITSERVER_URL", @base)
    System.put_env("LIVE_TEST_UNITSERVER_TOKEN", "t")
    on_exit(fn -> System.delete_env("LIVE_TEST_UNITSERVER_URL") end)
    on_exit(fn -> System.delete_env("LIVE_TEST_UNITSERVER_TOKEN") end)

    assert %{base: @base} = MastodonApi.from_env("unitserver")

    System.delete_env("LIVE_TEST_UNITSERVER_TOKEN")
    assert MastodonApi.from_env("unitserver") == nil
  end

  test "resolving an account searches with resolve=true, as the person, and returns the match" do
    test_pid = self()

    mock(fn %{method: :get} = env ->
      send(test_pid, {:seen, seen(env)})

      json(%{
        "accounts" => [
          %{"id" => "1", "acct" => "other@elsewhere"},
          %{
            "id" => "42",
            "acct" => "group@bonfire.example",
            "url" => "https://bonfire.example/group"
          }
        ]
      })
    end)

    assert {:ok, %{"id" => "42"}} =
             MastodonApi.resolve_account(client(), "@group@bonfire.example")

    assert_received {:seen, seen}
    assert seen.url =~ "/api/v2/search"
    assert seen.query["q"] == "@group@bonfire.example"
    assert seen.query["resolve"] == "true"

    # Mitra reads `type=accounts` as "profiles already in the database only" and skips resolving, so an unknown actor URL comes back empty
    refute Map.has_key?(seen.query, "type")
    assert seen.auth == "Bearer secret-token"
  end

  describe "shows_post?/3, whether a home timeline entry is a group's post, in either way a server shows it" do
    @post "https://bonfire.example/pub/objects/post1"
    @group "https://bonfire.example/pub/group/g1"

    test "a boost of the post is" do
      assert MastodonApi.shows_post?(
               %{"uri" => "x", "reblog" => %{"uri" => @post}},
               @post,
               @group
             )
    end

    test "the post itself, filed in the group, is (a server that does not boost a group's relayed post)" do
      entry = %{"uri" => @post, "reblog" => nil, "group" => %{"actor_id" => @group}}
      assert MastodonApi.shows_post?(entry, @post, @group)
    end

    test "the post itself with no group, or in another group, is not" do
      refute MastodonApi.shows_post?(%{"uri" => @post, "reblog" => nil}, @post, @group)
      refute MastodonApi.shows_post?(%{"uri" => @post, "group" => nil}, @post, @group)

      refute MastodonApi.shows_post?(
               %{"uri" => @post, "group" => %{"actor_id" => "https://other.example/g"}},
               @post,
               @group
             )
    end

    test "another post in the group, or a boost of another post, is not" do
      refute MastodonApi.shows_post?(
               %{
                 "uri" => "https://bonfire.example/pub/objects/other",
                 "group" => %{"actor_id" => @group}
               },
               @post,
               @group
             )

      refute MastodonApi.shows_post?(
               %{"uri" => "x", "reblog" => %{"uri" => "other"}},
               @post,
               @group
             )
    end
  end

  test "an account that does not resolve is an error, not the first unrelated result" do
    mock(fn %{method: :get} ->
      json(%{"accounts" => [%{"id" => "1", "acct" => "other@elsewhere"}]})
    end)

    assert {:error, :not_found} = MastodonApi.resolve_account(client(), "@group@bonfire.example")
  end

  test "following posts to the account's follow endpoint and returns the relationship" do
    test_pid = self()

    mock(fn %{method: :post} = env ->
      send(test_pid, {:seen, seen(env)})
      json(%{"id" => "42", "following" => false, "requested" => false})
    end)

    assert {:ok, %{"id" => "42"}} = MastodonApi.follow(client(), "42")

    assert_received {:seen, seen}
    assert seen.url == "#{@base}/api/v1/accounts/42/follow"
    assert seen.auth == "Bearer secret-token"
  end

  test "reading the home timeline asks for a page of statuses" do
    test_pid = self()

    mock(fn %{method: :get} = env ->
      send(test_pid, {:seen, seen(env)})
      json([%{"id" => "9"}])
    end)

    assert {:ok, [%{"id" => "9"}]} = MastodonApi.home_timeline(client(), limit: 20)

    assert_received {:seen, seen}
    assert seen.url =~ "/api/v1/timelines/home"
    assert seen.query["limit"] == "20"
  end

  test "posting a reply sends the text, the parent and the visibility" do
    test_pid = self()

    mock(fn %{method: :post} = env ->
      send(test_pid, {:seen, seen(env)})
      json(%{"id" => "77", "uri" => "https://social.example/statuses/77"})
    end)

    assert {:ok, %{"id" => "77"}} =
             MastodonApi.post_status(client(), "a reply from the remote",
               in_reply_to_id: "9",
               visibility: "public"
             )

    assert_received {:seen, seen}
    assert seen.url == "#{@base}/api/v1/statuses"

    body = if is_binary(seen.body), do: seen.body, else: inspect(seen.body)
    assert body =~ "a reply from the remote"
    assert body =~ "in_reply_to_id"
    assert body =~ "public"
  end

  test "deleting a status sends a DELETE for it" do
    test_pid = self()

    mock(fn %{method: :delete} = env ->
      send(test_pid, {:seen, seen(env)})
      json(%{"id" => "77"})
    end)

    assert {:ok, _} = MastodonApi.delete_status(client(), "77")

    assert_received {:seen, seen}
    assert seen.url == "#{@base}/api/v1/statuses/77"
  end

  test "a refusal comes back as the status and the body, so a failing run says why" do
    mock(fn %{method: :post} ->
      %Tesla.Env{status: 422, body: ~s({"error":"Validation failed"})}
    end)

    assert {:error, {422, %{"error" => "Validation failed"}}} = MastodonApi.follow(client(), "42")
  end
end
