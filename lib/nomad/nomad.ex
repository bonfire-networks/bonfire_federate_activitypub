defmodule Bonfire.Federate.ActivityPub.Nomad do
  @moduledoc """
  Acting as one account, on whichever server it is on.

  A context runs an action through `run/3`, giving what the action is for each transport: `Nomad.run(:publish, [opts], local: &publish/1)`. The account is the `current_user` in the args' opts. Nomad picks the transport for that account and runs what the context gave for it. Where the context gave nothing for that transport, it refuses with `{:error, {:not_supported, action, transport}}`, and never runs the local function instead: an action is never done here in the name of someone from elsewhere.

  Reads (`resolve/2`, `find_post/2`) are Nomad's own, as they are about the account's server, not about one context's action.

  This module is both the behaviour each transport implements and the functions callers use. Callers never call a transport module directly.

  Transports, by the key a context gives them under:

    * `:local`: our own instance, for a local user (`Nomad.Local`)
    * `:graphql`: the same document (`graphql: {document, variables}`, `variables` a function of the args), run two ways: `{:graphql, :local}`, our own instance through its GraphQL API in process, for a local user when the opts ask for it (`nomad_transport: :graphql`, so the same action can be run each way and come out the same) (`Nomad.GraphQL.Local`); and `{:graphql, :remote}`, a user from elsewhere through their Bonfire's GraphQL API over HTTP, with a token for it in the same opts (`bonfire_graphql_token`) (`Nomad.GraphQL.Remote`)
    * `:mastodon_api`: a user from elsewhere, through their own server's Mastodon API, with a token for it in the same opts (`mastodon_api_token`) (`Nomad.MastoAPI`)
    * `:remote`: a user from elsewhere with no token, so no way to act through their own server, and nothing runs for them
  """
  use Bonfire.Common.Utils

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @transports %{
    :local => Bonfire.Federate.ActivityPub.Nomad.Local,
    {:graphql, :local} => Bonfire.Federate.ActivityPub.Nomad.GraphQL.Local,
    {:graphql, :remote} => Bonfire.Federate.ActivityPub.Nomad.GraphQL.Remote,
    # disabled until the C2S plan is done (see `Nomad.C2S`): :c2s => Bonfire.Federate.ActivityPub.Nomad.C2S,
    :mastodon_api => Bonfire.Federate.ActivityPub.Nomad.MastoAPI
  }

  @doc "Runs the function or call the context gave for this transport, with the args."
  @callback run(given :: term(), args :: list()) :: term()

  # a transport may only read so far (the Mastodon API one), and then runs nothing
  @optional_callbacks run: 2

  @doc "Something by its URI, as the server knows it: what it holds already, else fetched."
  @callback resolve(uri :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "The post at `uri`, as the server has it, in the transport's own form (a Bonfire post for our own instance, a status for the Mastodon API)."
  @callback find_post(uri :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Runs `action` as the `current_user` in `args`, with what `given` has for that user's transport, or refuses."
  def run(action, args, given) when is_list(args) and is_list(given) do
    transport = transport(opts_in(args))

    with {:ok, module} <- module(action, transport, :run, 2),
         {:ok, what} <- given(given, action, transport) do
      module.run(what, args)
    end
  end

  # TODO: decide how to normalise what a transport gives back (`find_post`), eg. pass it to the federation adapter to create as a pointable object (if not already there), so callers get a Bonfire post from any server
  # each read, through the transport of the `current_user` in `opts`, which has a function of the same name
  for {name, doc} <- [
        resolve: "What the server of the `current_user` in `opts` knows `uri` as.",
        find_post:
          "The post at `uri`, as the server of the `current_user` in `opts` has it, in its transport's own form."
      ] do
    @doc doc
    def unquote(name)(uri, opts) do
      with {:ok, module} <- module(unquote(name), transport(opts), unquote(name), 2),
           do: module.unquote(name)(uri, opts)
    end
  end

  # the transport for the `current_user` in `opts`: ours for a local user; their server's API for a user from elsewhere with a token for it; else none
  defp transport(opts) do
    user = current_user(opts)

    cond do
      # not from inside a document `GraphQL.Local` runs, so a resolver going through `Nomad` again runs the local function (no loop)
      user && AdapterUtils.is_local?(user) && opts[:nomad_transport] == :graphql &&
          !Process.get(:nomad_in_local_graphql) ->
        {:graphql, :local}

      user && AdapterUtils.is_local?(user) ->
        :local

      is_binary(opts[:bonfire_graphql_token]) ->
        {:graphql, :remote}

      # disabled until the C2S plan is done (see `Nomad.C2S`): is_binary(opts[:c2s_token]) -> :c2s
      is_binary(opts[:mastodon_api_token]) ->
        :mastodon_api

      true ->
        :remote
    end
  end

  # the transport's module, if it is compiled here (the Mastodon API one only is where Hunter is) and has `function`
  defp module(action, transport, function, arity) do
    with {:ok, module} <- Map.fetch(@transports, transport),
         true <- Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      {:ok, module}
    else
      _ -> {:error, {:not_supported, action, transport}}
    end
  end

  # what the context gave for the transport, named explicitly (no default by the action's name, so each context says what runs where), else a refusal
  defp given(given, action, transport) do
    # a context gives each kind of transport once (`graphql:` for both ways of running it)
    case Keyword.fetch(given, if(is_tuple(transport), do: elem(transport, 0), else: transport)) do
      {:ok, what} -> {:ok, what}
      :error -> {:error, {:not_supported, action, transport}}
    end
  end

  @doc "The base URL of the server of the `current_user` in `opts` (the scheme, host and port of their actor), for a transport reaching it over HTTP; `nil` when it has none."
  def server(opts) do
    case opts |> current_user() |> Bonfire.Common.URIs.canonical_url() |> URI.parse() do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _ ->
        nil
    end
  end

  @doc "The opts with the account, among a context's args: the last of them with a `current_user` (a context's opts, usually its last arg), as the token for its transport sits beside it."
  def opts_in(args) do
    args
    |> Enum.reverse()
    |> Enum.find(fn
      arg when is_list(arg) or is_map(arg) -> current_user(arg)
      _ -> false
    end)
    |> Kernel.||([])
    |> to_options()
  end
end
