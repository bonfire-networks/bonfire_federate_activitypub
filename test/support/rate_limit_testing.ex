defmodule Bonfire.Federate.ActivityPub.RateLimit.Testing do
  @moduledoc """
  Testing helper for ActivityPub rate limits using Hammer 7.

  Provides utilities for testing rate limiting behavior on ActivityPub endpoints.
  """

  import Untangle

  @doc """
  Make rapid GET requests to an endpoint to test rate limiting.

  Returns a list of HTTP status codes from the responses.
  """
  def attack_endpoint(url, num_requests \\ 100, delay_ms \\ 10) do
    1..num_requests
    |> Enum.map(fn i ->
      Process.sleep(delay_ms)

      # Disable retry to prevent automatic backoff on 429 responses
      case Req.get(url, retry: false) do
        {:ok, %{status: status}} ->
          if rem(i, 10) == 0, do: info("Request #{i}: #{status}")
          status

        {:error, reason} ->
          warn(reason, "Request #{i} failed")
          :error
      end
    end)
  end

  @doc """
  Make rapid POST requests to an ActivityPub inbox.

  Returns a list of HTTP status codes from the responses.
  """
  def attack_inbox(url, activity, num_requests \\ 100, delay_ms \\ 10) do
    headers = [
      {"Content-Type", "application/activity+json"},
      {"Accept", "application/activity+json"}
    ]

    1..num_requests
    |> Enum.map(fn i ->
      Process.sleep(delay_ms)

      # Disable retry to prevent automatic backoff on 429 responses
      case Req.post(url, json: activity, headers: headers, retry: false) do
        {:ok, %{status: status}} ->
          if rem(i, 10) == 0, do: info("Request #{i}: #{status}")
          status

        {:error, reason} ->
          warn(reason, "Request #{i} failed")
          :error
      end
    end)
  end

  @doc """
  Count how many requests were throttled (returned 429).
  """
  def count_throttled(results) do
    Enum.count(results, &(&1 == 429))
  end

  @doc """
  Count how many requests were successful (returned 2xx).
  """
  def count_successful(results) do
    Enum.count(results, &(&1 in 200..299))
  end

  @doc """
  Generate a minimal ActivityPub activity for inbox testing.
  """
  def minimal_activity(actor_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Create",
      "id" => "http://test.example/activities/#{:rand.uniform(999_999)}",
      "actor" => actor_id,
      "object" => %{
        "type" => "Note",
        "id" => "http://test.example/notes/#{:rand.uniform(999_999)}",
        "content" => "Test note for rate limiting"
      }
    }
  end
end
