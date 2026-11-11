defmodule Bonfire.Federate.ActivityPub.AliasesAddPixelfedTest do
  @moduledoc """
  Adding a Pixelfed account as an external account (the "Add an external account" form of the profile settings) saves the account itself, not a link to the Pixelfed instance, whether it is given as a handle or as a profile URL.

  The WebFinger and actor documents have the shape Pixelfed serves: the actor id is `/users/<name>`, the profile page is `/<name>`.
  """

  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :backend

  use Bonfire.Common.E
  import Tesla.Mock
  alias Bonfire.Social.Graph.Aliases
  alias Bonfire.Federate.ActivityPub.Simulate

  @host "pixelfed.local"
  @handle "someone@#{@host}"
  @profile_url "https://#{@host}/someone"
  @actor_id "https://#{@host}/users/someone"

  defp actor_json do
    base = Simulate.actor_json("https://mocked.local/users/karen")

    Map.merge(base, %{
      "id" => @actor_id,
      "type" => "Person",
      "preferredUsername" => "someone",
      "name" => "Some One",
      "url" => @profile_url,
      "inbox" => @actor_id <> "/inbox",
      "outbox" => @actor_id <> "/outbox",
      "followers" => @actor_id <> "/followers",
      "following" => @actor_id <> "/following",
      "publicKey" => %{
        "id" => @actor_id <> "#main-key",
        "owner" => @actor_id,
        "publicKeyPem" => base["publicKey"]["publicKeyPem"]
      }
    })
  end

  defp webfinger_json do
    %{
      "subject" => "acct:#{@handle}",
      "aliases" => [@profile_url, @actor_id],
      "links" => [
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => @profile_url
        },
        %{
          "rel" => "http://schemas.google.com/g/2010#updates-from",
          "type" => "application/atom+xml",
          "href" => @actor_id <> ".atom"
        },
        %{"rel" => "self", "type" => "application/activity+json", "href" => @actor_id},
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => "https://#{@host}/authorize_interaction?uri={uri}"
        }
      ]
    }
  end

  setup do
    me = fake_user!()

    mock(fn
      %{method: :get, url: "https://#{@host}/.well-known/webfinger" <> _} ->
        json(webfinger_json())

      %{method: :get, url: @actor_id} ->
        json(actor_json())

      %{method: :get, url: @profile_url} ->
        json(actor_json())

      %{method: :get, url: "https://#{@host}/.well-known/nodeinfo" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, me: me}
  end

  defp assert_alias_is_the_remote_actor(%{edge: %{object_id: object_id}}) do
    assert {:ok, actor} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(@actor_id)

    assert object_id == id(actor)
  end

  test "a handle with a leading @ saves the account", %{me: me} do
    assert {:ok, added} = Aliases.add(me, "@" <> @handle)
    assert_alias_is_the_remote_actor(added)
  end

  test "a handle saves the account", %{me: me} do
    assert {:ok, added} = Aliases.add(me, @handle)
    assert_alias_is_the_remote_actor(added)
  end

  test "a handle that can't be resolved is not saved as a link to the instance", %{me: me} do
    mock(fn _ ->
      %Tesla.Env{status: 404, body: ""}
    end)

    # refute match?({:ok, _}, Aliases.add(me, "@nobody@#{@host}"))
    for handle <- ["@nobody@#{@host}", "nobody@#{@host}"] do
      assert {:error, _} = Aliases.add(me, handle)
    end

    assert [] = Aliases.list_my_aliases(me) |> e(:edges, [])
    assert {:error, _} = Bonfire.Files.Media.get_by_path("@nobody@#{@host}")
    assert {:error, _} = Bonfire.Files.Media.get_by_path("nobody@#{@host}")
  end

  test "a plain URL that is not an actor is saved as a link", %{me: me} do
    url = "https://blog.local/a-post"

    mock(fn
      %{method: :get, url: ^url} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>A post</title></head><body>hello</body></html>"
        }

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} = Aliases.add(me, url)
    assert %{path: ^url} = Bonfire.Files.Media.get_by_path(url) |> elem(1)
  end

  test "a profile URL saves the account", %{me: me} do
    assert {:ok, added} = Aliases.add(me, @profile_url)
    assert_alias_is_the_remote_actor(added)
  end
end
