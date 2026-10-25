defmodule Bonfire.Federate.ActivityPub.Nomad.GraphQL do
  @moduledoc "What `Nomad`'s two GraphQL transports share (`GraphQL.Local`, in process; `GraphQL.Remote`, over HTTP)."

  @doc "What a GraphQL answer's one field resolved to, or its errors."
  def result({:ok, %{errors: errors}}), do: {:error, {:graphql, errors}}
  def result({:ok, %{"errors" => errors}}), do: {:error, {:graphql, errors}}
  def result({:ok, %{data: data}}) when is_map(data), do: one_field(data)
  def result({:ok, %{"data" => data}}) when is_map(data), do: one_field(data)
  def result(other), do: {:error, {:graphql, other}}

  defp one_field(data) do
    case Map.values(data) do
      [value] -> {:ok, value}
      _ -> {:error, {:graphql, {:not_one_field, data}}}
    end
  end
end
