if Code.ensure_loaded?(Hunter) do
  defmodule Bonfire.Federate.ActivityPub.Nomad.MastoAPI do
    @moduledoc """
    `Nomad`'s transport for a user from elsewhere, through their own server's Mastodon API (through Hunter), with the token in the opts (`mastodon_api_token`). Their server is the host of their actor.

    Hunter raises on any answer that is not a 2xx, so each call here gives `{:error, {:mastodon_api, reason}}` instead.
    """
    @behaviour Bonfire.Federate.ActivityPub.Nomad

    use Bonfire.Common.Utils

    @doc "Runs the function of this module a context named (eg. `mastodon_api: :follow`), with the client for the opts in `args` first, then the args."
    @impl true
    def run(name, args) when is_atom(name) do
      with {:ok, client} <- client(Bonfire.Federate.ActivityPub.Nomad.opts_in(args)) do
        call(fn -> apply(__MODULE__, name, [client | args]) end)
        |> case do
          {:ok, result} -> result
          error -> error
        end
      end
    end

    # each action on their server's account for one of our actors (found by its URI, `resolve=true`, so their server fetches it if it does not know it yet), through Hunter's function of the same name
    for name <- [:follow, :unfollow] do
      def unquote(name)(client, _subject, object, _opts) do
        with {:ok, account} <- account_for(client, object),
             do: {:ok, Hunter.unquote(name)(client, account.id)}
      end
    end

    @doc "Posts a status from `Posts.publish/1`'s opts: the text of the HTML body (the Mastodon API takes plain text, and makes its own links of hashtags and mentions), public unless a boundary says otherwise."
    def publish(client, opts) do
      body = get_in(opts, [:post_attrs, :post_content, :html_body]) || ""

      {:ok,
       Hunter.create_status(client, Bonfire.Common.Text.text_only(body) || "",
         visibility: visibility(opts[:boundary])
       )}
    end

    defp visibility(boundary) when boundary in [nil, "public"], do: "public"
    defp visibility("local"), do: "unlisted"
    defp visibility("mentions"), do: "direct"
    defp visibility(_), do: "private"

    # their server's account for one of our actors
    defp account_for(client, object) do
      uri = Bonfire.Common.URIs.canonical_url(object)

      # no `type`: Mitra resolves no URL in a search limited to accounts (25 October), as a plain search with `resolve` does on both it and Mastodon
      case Hunter.search(client, uri, resolve: true) do
        %Hunter.Result{accounts: [account | _]} -> {:ok, account}
        _ -> {:error, {:not_found, uri}}
      end
    end

    @impl true
    def resolve(uri, opts) do
      with {:ok, client} <- client(opts),
           {:ok, %Hunter.Result{} = result} <-
             call(fn -> Hunter.search(client, uri, resolve: true) end) do
        case result do
          %{statuses: [status | _]} -> {:ok, status}
          %{accounts: [account | _]} -> {:ok, account}
          _ -> {:error, {:not_found, uri}}
        end
      end
    end

    @doc "For `FeedLoader.nomad(:feed_contains?, ...)`: the post among their home timeline's latest statuses; only `:my` (their home) is a feed the API shows."
    def feed_contains?(client, :my, uri, _opts),
      do: client |> Hunter.home_timeline(limit: 40) |> Enum.any?(&(&1.uri == uri))

    def feed_contains?(_client, _feed, _uri, _opts), do: nil

    @doc "For `Threads.nomad(:thread_contains?, ...)`: the reply among the post's descendants (its context)."
    def thread_contains?(client, post_uri, reply_uri, opts) do
      case find_post(post_uri, opts) do
        {:ok, %Hunter.Status{id: post_id}} ->
          %Hunter.Context{descendants: descendants} = Hunter.status_context(client, post_id)
          Enum.any?(List.wrap(descendants), &(&1.uri == reply_uri))

        _ ->
          false
      end
    end

    @impl true
    def find_post(uri, opts) do
      with {:ok, %Hunter.Status{} = status} <- resolve(uri, opts) do
        {:ok, status}
      else
        {:ok, other} -> {:error, {:not_a_post, uri, other}}
        other -> other
      end
    end

    # a Hunter client for the server of the `current_user` in `opts`, with their token
    defp client(opts) do
      with token when is_binary(token) <- opts[:mastodon_api_token],
           base when is_binary(base) <- Bonfire.Federate.ActivityPub.Nomad.server(opts) do
        {:ok, %Hunter.Client{base_url: base, access_token: token}}
      else
        _ -> {:error, {:mastodon_api, :no_server_or_token}}
      end
    end

    defp call(fun) do
      {:ok, fun.()}
    rescue
      e in Hunter.Error -> {:error, {:mastodon_api, e.reason}}
    end
  end
end
