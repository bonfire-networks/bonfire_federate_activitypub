defmodule Bonfire.Federate.ActivityPub.Nomad.GraphQL.Remote do
  @moduledoc """
  `Nomad`'s `{:graphql, :remote}` transport: a user from elsewhere whose server is a Bonfire, through its GraphQL API over HTTP (`/api/graphql`), with the token for it in the opts (`bonfire_graphql_token`). Runs the same document as `GraphQL.Local` does in process (`graphql: {document, variables}`), on their server, and gives back what its one field resolved to.
  """
  @behaviour Bonfire.Federate.ActivityPub.Nomad

  alias Bonfire.Federate.ActivityPub.Nomad

  @impl true
  def run({document, variables}, args) do
    opts = Nomad.opts_in(args)

    with token when is_binary(token) <- opts[:bonfire_graphql_token],
         base when is_binary(base) <- Nomad.server(opts),
         {:ok, %{status: 200, body: body}} <-
           Bonfire.Common.HTTP.post(
             base <> "/api/graphql",
             Jason.encode!(%{query: document, variables: apply(variables, args)}),
             [{"content-type", "application/json"}, {"authorization", "Bearer " <> token}]
           ),
         {:ok, answer} <- decode(body) do
      Nomad.GraphQL.result({:ok, answer})
    else
      {:ok, %{status: status, body: body}} -> {:error, {:graphql, :remote, status, body}}
      other -> {:error, {:graphql, :remote, other}}
    end
  end

  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(body) when is_map(body), do: {:ok, body}
end
