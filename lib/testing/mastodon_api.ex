# dev/test-only, like `Testing.Interop`: not compiled into prod releases at all
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.MastodonApi do
    @moduledoc """
    A small client for acting as a person on a remote server that speaks the Mastodon-compatible API (Mastodon, GoToSocial, Akkoma, Pleroma, Sharkey, Firefish, Mitra), for the live account tests: look an account up, follow it, read the timelines, post and delete.

    A client is built from a base URL and an access token. `from_env/1` reads them from `LIVE_TEST_<NAME>_URL` and `LIVE_TEST_<NAME>_TOKEN` (`.env` is git-ignored, so that is where they belong), and gives `nil` when either is unset, so a test can skip itself. The token needs the `read`, `write` and `follow` scopes.

    Every call returns `{:ok, decoded_json}`, or `{:error, {status, body}}` for a refusal so a failing run says why, or `{:error, reason}` when the request never got an answer.
    """

    alias Bonfire.Common.HTTP

    defstruct [:base, :token]

    @type t :: %__MODULE__{base: String.t(), token: String.t()}

    @doc "A client for `base_url`, acting as the owner of `token`."
    def new(base_url, token) do
      if blank?(base_url) or blank?(token),
        do: raise(ArgumentError, "a Mastodon API client needs both a URL and a token"),
        else: %__MODULE__{base: String.trim_trailing(base_url, "/"), token: token}
    end

    @doc "The client for `LIVE_TEST_<NAME>_URL` and `LIVE_TEST_<NAME>_TOKEN`, or `nil` if either is not set."
    def from_env(name) do
      key = name |> to_string() |> String.upcase()
      url = System.get_env("LIVE_TEST_#{key}_URL")
      token = System.get_env("LIVE_TEST_#{key}_TOKEN")

      if blank?(url) or blank?(token), do: nil, else: new(url, token)
    end

    @doc """
    Finds the account for `handle` (`@name@host`, `name@host`, or its URL), making the server fetch it from its home if it does not know it yet (`resolve=true`). Another account the search returns along with it is not taken for it: no match is `{:error, :not_found}`.
    """
    def resolve_account(%__MODULE__{} = client, handle) do
      wanted = handle |> to_string() |> String.trim_leading("@") |> String.downcase()

      with {:ok, %{"accounts" => accounts}} <-
             get(client, "/api/v2/search", q: handle, resolve: true, limit: 5) do
        case Enum.find(accounts, &account_matches?(&1, wanted)) do
          nil -> {:error, :not_found}
          account -> {:ok, account}
        end
      end
    end

    defp account_matches?(account, wanted) do
      [account["acct"], account["url"], account["uri"]]
      |> Enum.any?(&(is_binary(&1) and String.downcase(&1) == wanted))
    end

    def follow(%__MODULE__{} = client, account_id),
      do: post(client, "/api/v1/accounts/#{account_id}/follow")

    def unfollow(%__MODULE__{} = client, account_id),
      do: post(client, "/api/v1/accounts/#{account_id}/unfollow")

    @doc "The relationship of the token's account with `account_id` (is it following, is it waiting for approval)."
    def relationship(%__MODULE__{} = client, account_id) do
      with {:ok, [relationship | _]} <-
             get(client, "/api/v1/accounts/relationships", [{"id[]", account_id}]) do
        {:ok, relationship}
      end
    end

    @doc "The home timeline, newest first. Options: `:limit` (default 40)."
    def home_timeline(%__MODULE__{} = client, opts \\ []),
      do: get(client, "/api/v1/timelines/home", limit: opts[:limit] || 40)

    @doc """
    Whether a home timeline `entry` is the post `ap_id` as a follower of the group `group_url` sees it. Servers differ: most show a boost by the group, while one that files a relayed post under the group itself (Mitra) shows the post as its author's status with a `group` field. Both count; a post with no group, or in another one, does not.
    """
    def shows_post?(entry, ap_id, group_url) do
      get_in(entry, ["reblog", "uri"]) == ap_id or
        (entry["uri"] == ap_id and get_in(entry, ["group", "actor_id"]) == group_url)
    end

    @doc "The statuses of an account, newest first. Options: `:limit` (default 40)."
    def account_statuses(%__MODULE__{} = client, account_id, opts \\ []),
      do: get(client, "/api/v1/accounts/#{account_id}/statuses", limit: opts[:limit] || 40)

    def status(%__MODULE__{} = client, status_id), do: get(client, "/api/v1/statuses/#{status_id}")

    def status_context(%__MODULE__{} = client, status_id),
      do: get(client, "/api/v1/statuses/#{status_id}/context")

    @doc """
    Posts a status. Options: `:in_reply_to_id`, `:visibility` (default `"public"`), `:spoiler_text`.
    """
    def post_status(%__MODULE__{} = client, text, opts \\ []) do
      body =
        %{status: text, visibility: opts[:visibility] || "public"}
        |> put_unless_nil(:in_reply_to_id, opts[:in_reply_to_id])
        |> put_unless_nil(:spoiler_text, opts[:spoiler_text])

      post(client, "/api/v1/statuses", body)
    end

    def delete_status(%__MODULE__{} = client, status_id),
      do: request(client, :delete, "/api/v1/statuses/#{status_id}", "", [])

    defp get(client, path, params \\ []), do: request(client, :get, path, "", params)

    defp post(client, path, body \\ %{}), do: request(client, :post, path, body, [])

    defp request(client, method, path, body, params) do
      body = if is_map(body), do: Jason.encode!(body), else: body

      headers = [
        {"authorization", "Bearer #{client.token}"},
        {"accept", "application/json"},
        {"content-type", "application/json"}
      ]

      case HTTP.request(method, client.base <> path, body, headers, params: params) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          {:ok, decode(response)}

        {:ok, %{status: status, body: response}} ->
          {:error, {status, decode(response)}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp decode(body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        _ -> body
      end
    end

    defp decode(body), do: body

    defp put_unless_nil(map, _key, nil), do: map
    defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

    defp blank?(value), do: value in [nil, ""]
  end
end
