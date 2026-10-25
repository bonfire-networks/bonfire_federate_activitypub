defmodule Bonfire.Federate.ActivityPub.Nomad.GraphQL.Local do
  @moduledoc """
  `Nomad`'s `{:graphql, :local}` transport: our own instance through its GraphQL API, in process, for a local user when the opts ask for it (`nomad_transport: :graphql`). Runs the document the context gave (`graphql: {document, variables}`) against `Bonfire.API.GraphQL.Schema`, as the user, and gives back what its one field resolved to.

  It runs the document with `Absinthe.run/3`, with the schema's own context (as `AbsintheClient` does, which only takes documents given at compile time).
  """
  @behaviour Bonfire.Federate.ActivityPub.Nomad

  alias Bonfire.Federate.ActivityPub.Nomad

  @impl true
  def run({document, variables}, args) do
    user = Bonfire.Common.Utils.current_user(Nomad.opts_in(args))
    schema = Bonfire.API.GraphQL.Schema

    # marked while the document runs, so a resolver that goes through `Nomad` again runs the local function, never this transport again (no loop)
    previous = Process.put(:nomad_in_local_graphql, true)

    try do
      document
      |> Absinthe.run(schema,
        variables: apply(variables, args),
        context: schema.context(%{current_user: user})
      )
      |> Nomad.GraphQL.result()
    after
      if previous,
        do: Process.put(:nomad_in_local_graphql, previous),
        else: Process.delete(:nomad_in_local_graphql)
    end
  end
end
