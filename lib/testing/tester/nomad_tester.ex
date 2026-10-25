# dev/test-only, like `Testing.Interop`: not compiled into prod releases at all
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.Tester.NomadTester do
    @moduledoc """
    An account acting through `Bonfire.Federate.ActivityPub.Nomad`, as Bring your own identity's users will: its actions go through the contexts' `nomad` functions (`Posts.nomad(:publish, ...)`, `Follows.nomad(:follow, ...)`), and its reads through `Nomad`, so a test covers the path real code takes, whichever server the account is on.

    Which account, from the context it is made with (`context[:account]`, or `Tester.new({Tester.NomadTester, account}, context)`):

      * `:local` (the default): the test's local user, `context[:local][:user]`
      * `{:dance_instance, :remote}`: the dance's remote user, local on the dance's other instance, so acting there as `:local` does here: every call runs in `Bonfire.Common.TestInstanceRepo.apply/1`, and what it accepted of a delivery is read from that instance's database (the strongest evidence a tester can give)
      * `{:graphql, :local}`: the test's local user, through our GraphQL API in process (`nomad_transport: :graphql`)
      * `{:graphql, :remote}`: the dance's remote user, as our instance knows them, through the other instance's GraphQL API over HTTP, with a token from its `login` mutation
      * `{:mastodon_api, server}`: a real server's account, the `.env` one for `server` (`LIVE_TEST_<NAME>_URL` and `LIVE_TEST_<NAME>_TOKEN`, see `Testing.MastodonApi.from_env/1`), acting as its remote user here with its token. Only the live recipe runs it (`:live_federation`), as it reaches a real server, which has to reach our instance in turn.

    The two differ only in their opts (a token for the API) and in what a real server needs: waiting for it, cleaning up after a test (`unfollow`), and reading back through its API what it did with a delivery.
    """
    @behaviour Bonfire.Federate.ActivityPub.Testing.Tester

    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias Bonfire.Federate.ActivityPub.Nomad
    alias Bonfire.Federate.ActivityPub.Testing.Interop
    alias Bonfire.Federate.ActivityPub.Testing.MastodonApi

    @impl true
    def new(context), do: account(context[:account] || :local, context)

    defp account(:local, context), do: %{user: context[:local][:user], opts: []}

    defp account({:dance_instance, :remote}, context),
      do: %{user: context[:remote][:user], opts: [], on_dance_instance: true}

    defp account({:graphql, :local}, context),
      do: %{user: context[:local][:user], opts: [nomad_transport: :graphql]}

    # the dance's remote user here (fetched from the other instance), and a token from its own GraphQL API, as a client signing in there would get
    defp account({:graphql, :remote}, context) do
      {:ok, user} = actor(context[:remote][:canonical_url])
      username = e(context[:remote][:user], :character, :username, nil)

      {:ok, %{"token" => token}} =
        graphql_login(Nomad.server(current_user: user), username, context[:test_password])

      # and the user on that instance, to read there what it accepted of a delivery
      %{user: user, opts: [bonfire_graphql_token: token], dance_user: context[:remote][:user]}
    end

    # the account's remote user here (fetched from its server), and its token
    defp account({:mastodon_api, server}, _context) do
      api =
        MastodonApi.from_env(server) ||
          raise ArgumentError, "no LIVE_TEST_ account in .env for #{inspect(server)}"

      {:ok, account} = MastodonApi.verify_credentials(api)
      {:ok, user} = actor("@#{account["acct"]}@#{URI.parse(api.base).host}")

      %{user: user, opts: [mastodon_api_token: api.token], api: api, wait: wait()}
    end

    defp graphql_login(base, username, password) do
      with {:ok, %{status: 200, body: body}} <-
             Bonfire.Common.HTTP.post(
               base <> "/api/graphql",
               Jason.encode!(%{
                 query:
                   "mutation ($u: String!, $p: String!) { login(email_or_username: $u, password: $p) { token } }",
                 variables: %{u: username, p: password}
               }),
               [{"content-type", "application/json"}]
             ) do
        Nomad.GraphQL.result({:ok, if(is_binary(body), do: Jason.decode!(body), else: body)})
      end
    end

    # how long each step waits for a real server, in seconds (`LIVE_TEST_ACCEPT_WAIT`, as the other live tests)
    defp wait, do: String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")

    defp opts(%{user: user, opts: opts}), do: [current_user: user] ++ opts

    # runs `fun` on the instance the account is on: the dance's other one through `apply`, else this one
    defp on(%{on_dance_instance: true}, fun), do: Bonfire.Common.TestInstanceRepo.apply(fun)
    defp on(_state, fun), do: fun.()

    @impl true
    def post(state, post_attrs) do
      on(state, fn ->
        Bonfire.Posts.nomad(:publish, opts(state) ++ [post_attrs: post_attrs, boundary: "public"])
      end)
    end

    # a fresh user on the account's instance replies, so the replier is no follower of ours; the post is found there by its URI
    @impl true
    def reply(%{api: _}, uri, _post_attrs), do: {:error, {:no_reply_through_the_api_yet, uri}}

    def reply(state, uri, post_attrs) do
      on(state, fn ->
        replier = Bonfire.Me.Fake.fake_user!("Replier")

        with {:ok, post} <- AdapterUtils.get_by_url_ap_id_or_username(uri) do
          Bonfire.Posts.nomad(:publish,
            current_user: replier,
            post_attrs: Map.put(post_attrs, :reply_to_id, post.id),
            boundary: "public"
          )
        end
      end)
    end

    @impl true
    def uri_of(_state, %Hunter.Status{uri: uri}), do: uri
    # what the `create_post` mutation gave back
    def uri_of(_state, %{"activity" => %{"canonical_uri" => uri}}), do: uri

    def uri_of(state, post),
      do: on(state, fn -> Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true) end)

    @impl true
    def resolve(state, uri), do: on(state, fn -> Nomad.resolve(uri, opts(state)) end)

    @impl true
    def find_post(state, uri) do
      on(state, fn ->
        with {:ok, post} <- Nomad.find_post(uri, opts(state)), do: {:ok, found_post(post)}
      end)
    end

    @doc "A post as `Testing.Tester`'s `found_post` map, from whichever form the transport gave it in: a Bonfire post (its HTML body, its hashtags' names, its media with their alt text, and whether it is sensitive; the dance's other instance is a Bonfire too, so it uses this as well), or a Mastodon API status."
    def found_post(%Hunter.Status{} = status) do
      %{
        content: status.content,
        tags: for(tag <- List.wrap(status.tags), do: tag.name),
        media:
          for(
            attachment <- List.wrap(status.media_attachments),
            do: %{alt: attachment.description, url: attachment.url}
          ),
        sensitive: status.sensitive == true
      }
    end

    def found_post(post) do
      post = repo().maybe_preload(post, [:post_content, :sensitive, :media])

      %{
        content: e(post, :post_content, :html_body, nil),
        tags:
          post
          |> Bonfire.Social.Tags.list_tags_hashtags()
          |> repo().maybe_preload(:named)
          |> Enum.map(&e(&1, :named, :name, nil))
          |> Enum.reject(&is_nil/1),
        media:
          for media <- List.wrap(e(post, :media, [])) do
            %{alt: Bonfire.Files.Media.media_alt(media, false), url: e(media, :path, nil)}
          end,
        sensitive: e(post, :sensitive, :is_sensitive, nil) == true
      }
    end

    # follows through `Nomad` (`Follows.nomad(:follow, ...)`); a real server is asked again while it fetches our user through the tunnel, and its Follow is waited for
    @impl true
    def follow(state, uri) do
      {:ok, ours} = on(state, fn -> actor(uri) end)

      follow = fn ->
        on(state, fn ->
          Bonfire.Social.Graph.Follows.nomad(:follow, state.user, ours, opts(state))
        end)
      end

      with {:ok, _} <- maybe_await(state, follow, uri),
           true <-
             (!state[:api] or
                !!Interop.await_incoming([type: "Follow", about: uri], seconds: state.wait)) ||
               {:error, {:no_follow_reached_us, uri}} do
        # kept, so `unfollow` needs no second lookup (on 25 October one at the end of the forwarding scenario found nothing)
        {:ok, Map.update(state, :followed, %{uri => ours}, &Map.put(&1, uri, ours))}
      end
    end

    defp maybe_await(%{api: _, wait: wait}, follow, uri) do
      # asked once more, so the failure says why
      Interop.await(
        fn ->
          case follow.() do
            {:ok, _} = ok -> ok
            _ -> nil
          end
        end,
        seconds: wait
      ) ||
        {:error, {:could_not_follow, uri, follow.()}}
    end

    defp maybe_await(_state, follow, _uri), do: follow.()

    # a real person's account stops following once the test is done (who it followed, as `follow` kept them); the local user has nothing to clean up
    @impl true
    def unfollow(%{api: _} = state, uri) do
      case state[:followed][uri] do
        nil -> {:error, {:not_followed_here, uri}}
        ours -> Bonfire.Social.Graph.Follows.nomad(:unfollow, state.user, ours, opts(state))
      end
    end

    def unfollow(_state, _uri), do: :ok

    # an actor by its URI or handle (one of ours, or the account's remote user here), with what its URI is built from (`Nomad.MastoAPI` finds ours on their server by that URI)
    defp actor(uri) do
      with {:ok, actor} <- AdapterUtils.get_by_url_ap_id_or_username(uri),
           # `prune: true`, as the adapter does: an actor may be no user (a group is a category, with no `shared_user`)
           do:
             {:ok, repo().maybe_preload(actor, [:shared_user, character: [:peered]], prune: true)}
    end

    # what the follower's server shows of a post we delivered, through the contexts' `nomad` reads whichever server it is on: a reply in the thread of the post it replies to (found from our copy of the reply's `inReplyTo`), else the post in the follower's home feed
    @impl true
    def delivery_outcome(%{on_dance_instance: true} = state, uri), do: shown(state, uri)

    # acting through the dance's other instance's API, but its user there, so what it accepted is read there, as for that instance's own account
    def delivery_outcome(%{dance_user: dance_user} = state, uri),
      do:
        shown(
          %{user: dance_user, opts: [], on_dance_instance: true, wait: state[:wait]},
          uri
        )

    def delivery_outcome(%{api: _} = state, uri), do: shown(state, uri)
    def delivery_outcome(_state, uri), do: {:refused, {:no_delivery_to_ourselves, uri}}

    defp shown(state, uri) do
      {check, where} =
        case ActivityPub.Object.get_cached(ap_id: uri) do
          {:ok, %{data: %{"inReplyTo" => post_uri}}} when is_binary(post_uri) ->
            {fn ->
               Bonfire.Social.Threads.nomad(:thread_contains?, post_uri, uri, opts(state))
             end, {:thread, post_uri}}

          _ ->
            {fn -> Bonfire.Social.FeedLoader.nomad(:feed_contains?, :my, uri, opts(state)) end,
             :my}
        end

      # only `true` counts: a refusal (`{:error, _}`) is no answer
      if Interop.await(fn -> on(state, check) == true end, seconds: state[:wait] || 60),
        do: {:accepted, {:shown_in, where}},
        else: {:refused, {:not_shown_in, where, uri}}
    end
  end
end
