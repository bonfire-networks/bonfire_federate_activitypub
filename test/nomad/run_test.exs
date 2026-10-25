defmodule Bonfire.Federate.ActivityPub.Nomad.RunTest do
  @moduledoc """
  `Nomad.run/3`: an action runs as the account in the args' `current_user`, through the transport for that account, and only with what the caller gave for that transport. A local user gets the local function; anyone else gets a refusal, never the local function in their name.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.Nomad
  alias Bonfire.Federate.ActivityPub.Simulate

  setup do
    # the remote user's actor and images, as `Simulate.fake_remote_user/0` fetches them
    Tesla.Mock.mock(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)
    :ok
  end

  test "for a local user, runs the local function the caller gave" do
    me = fake_user!()
    test_pid = self()

    assert {:ok, :posted} =
             Nomad.run(:post, [[current_user: me]],
               local: fn opts ->
                 send(test_pid, {:ran, opts})
                 {:ok, :posted}
               end
             )

    assert_received {:ran, opts}
    assert id(opts[:current_user]) == id(me)
  end

  test "for a remote user, with no transport to act as them, refuses and never runs the local function" do
    {:ok, remote} = Simulate.fake_remote_user()
    test_pid = self()

    assert {:error, {:not_supported, :post, :remote}} =
             Nomad.run(:post, [[current_user: remote]],
               local: fn _opts -> send(test_pid, :ran) end
             )

    refute_received :ran
  end

  test "with `nomad_transport: :graphql`, Posts.nomad(:publish, opts) publishes through our GraphQL API in process, giving back what the mutation gives" do
    me = fake_user!()

    assert {:ok, %{"id" => id, "activity" => %{"canonical_uri" => uri}}} =
             Bonfire.Posts.nomad(:publish,
               current_user: me,
               nomad_transport: :graphql,
               post_attrs: %{post_content: %{html_body: "a post through GraphQL"}},
               boundary: "public"
             )

    assert is_binary(uri)
    assert {:ok, post} = Bonfire.Posts.read(id, current_user: me)

    assert e(repo().maybe_preload(post, :post_content), :post_content, :html_body, nil) =~
             "a post through GraphQL"

    # the mutation's resolver goes through `Nomad` again, which runs the local function there: one post, no loop
    assert [_one] = Bonfire.Posts.list_by(me, current_user: me) |> e(:edges, [])
  end

  test "with `nomad_transport: :graphql`, Follows.nomad follows and unfollows through our GraphQL API in process, with the document the Mastodon API runs too" do
    me = fake_user!()
    other = fake_user!()
    opts = [current_user: me, nomad_transport: :graphql]

    assert {:ok, %{"id" => _}} = Bonfire.Social.Graph.Follows.nomad(:follow, me, other, opts)
    assert Bonfire.Social.Graph.Follows.following?(me, other)

    assert {:ok, true} = Bonfire.Social.Graph.Follows.nomad(:unfollow, me, other, opts)
    refute Bonfire.Social.Graph.Follows.following?(me, other)
  end

  test "Posts.nomad(:publish, opts) publishes as a local user, and Nomad.find_post finds that post" do
    me = fake_user!()

    assert {:ok, post} =
             Bonfire.Posts.nomad(:publish,
               current_user: me,
               post_attrs: %{post_content: %{html_body: "a post with #elixir #bonfire"}},
               boundary: "public"
             )

    url = Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)

    # our own instance gives the post itself
    assert {:ok, %Bonfire.Data.Social.Post{} = found} = Nomad.find_post(url, current_user: me)
    assert id(found) == id(post)
  end
end
