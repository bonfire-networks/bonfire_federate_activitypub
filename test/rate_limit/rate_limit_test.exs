defmodule Bonfire.Federate.ActivityPub.RateLimitTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  import Untangle
  alias Bonfire.Federate.ActivityPub.Web.RateLimit.Testing

  @moduletag :test_instance

  describe "WebFinger endpoint rate limiting" do
    test "throttles excessive requests to WebFinger", context do
      # Access the local user from context
      local_user = context[:local]
      username = local_user[:user].character.username
      url = "http://localhost:4000/.well-known/webfinger?resource=acct:#{username}@localhost"

      info("Testing WebFinger rate limit (200 req/60s)")

      # Make 250 requests quickly (should hit the 200 limit)
      results = Testing.attack_endpoint(url, 250, 5)

      throttled = Testing.count_throttled(results)
      successful = Testing.count_successful(results)

      info("WebFinger results: #{successful} successful, #{throttled} throttled")

      # Should have some throttled requests
      assert throttled > 0, "Expected some requests to be throttled"
      # Should have allowed around 200 requests
      assert successful >= 190 and successful <= 210,
             "Expected around 200 successful requests, got #{successful}"
    end
  end

  describe "ActivityPub API endpoint rate limiting" do
    test "throttles excessive requests to actor endpoint", context do
      local_user = context[:local]
      username = local_user[:user].character.username
      url = "http://localhost:4000/pub/actors/#{username}"

      info("Testing ActivityPub API rate limit (3000 req/120s)")

      # Make 500 requests quickly (well under the 3000 limit)
      results = Testing.attack_endpoint(url, 500, 5)

      throttled = Testing.count_throttled(results)
      successful = Testing.count_successful(results)

      info("API results: #{successful} successful, #{throttled} throttled")

      # Should NOT be throttled at 500 requests
      assert throttled == 0, "Should not throttle at 500 requests (limit is 3000)"
      assert successful >= 490, "Most requests should succeed"
    end
  end

  #   describe "Redirect endpoint rate limiting" do
  #     test "throttles excessive requests to redirect endpoint", context do
  #       local_user = context[:local]
  #       username = local_user[:user].character.username
  #       url = "http://localhost:4000/pub/actors/#{username}"

  #       info("Testing Redirect rate limit (200 req/60s)")

  #       # Make 250 HTML requests (should trigger redirect rate limit)
  #       results = Testing.attack_endpoint(url, 250, 5)

  #       throttled = Testing.count_throttled(results)
  #       successful = Testing.count_successful(results)

  #       info("Redirect results: #{successful} successful, #{throttled} throttled")

  #       # Should have some throttled requests
  #       assert throttled > 0, "Expected some requests to be throttled"
  #       # Should have allowed around 200 requests
  #       assert successful >= 190 and successful <= 210,
  #         "Expected around 200 successful requests, got #{successful}"
  #     end
  #   end

  describe "Incoming ActivityPub endpoint rate limiting" do
    test "throttles excessive POST requests to shared inbox", context do
      remote_user = context[:remote]
      url = "http://localhost:4000/pub/shared-inbox"
      activity = Testing.minimal_activity(remote_user[:user].id)

      info("Testing Incoming ActivityPub rate limit (5000 req/120s)")

      # Make 500 requests quickly (well under the 5000 limit)
      results = Testing.attack_inbox(url, activity, 500, 5)

      throttled = Testing.count_throttled(results)
      # Note: Some may fail validation, so we count both success and errors
      not_throttled = Enum.count(results, &(&1 != 429))

      info("Incoming results: #{not_throttled} not throttled, #{throttled} throttled")

      # Should NOT be throttled at 500 requests
      assert throttled == 0, "Should not throttle at 500 requests (limit is 5000)"
    end
  end

  describe "Rate limit independence" do
    test "different endpoints have independent rate limits", context do
      local_user = context[:local]
      username = local_user[:user].character.username

      # Hit WebFinger endpoint
      webfinger_url =
        "http://localhost:4000/.well-known/webfinger?resource=acct:#{username}@localhost"

      webfinger_results = Testing.attack_endpoint(webfinger_url, 250, 5)

      # Hit API endpoint (should not be affected by WebFinger rate limit)
      api_url = "http://localhost:4000/pub/actors/#{username}"
      api_results = Testing.attack_endpoint(api_url, 100, 5)

      webfinger_throttled = Testing.count_throttled(webfinger_results)
      api_throttled = Testing.count_throttled(api_results)
      api_successful = Testing.count_successful(api_results)

      info("WebFinger throttled: #{webfinger_throttled}")
      info("API throttled: #{api_throttled}, successful: #{api_successful}")

      # WebFinger should be throttled
      assert webfinger_throttled > 0, "WebFinger should be throttled"

      # API should NOT be affected by WebFinger rate limit
      assert api_throttled == 0, "API should not be throttled (independent limits)"
      assert api_successful >= 95, "Most API requests should succeed"
    end
  end

  describe "Rate limit recovery" do
    test "rate limit resets after time window expires", context do
      local_user = context[:local]
      username = local_user[:user].character.username
      url = "http://localhost:4000/.well-known/webfinger?resource=acct:#{username}@localhost"

      info("Testing rate limit recovery")

      # Exhaust the rate limit
      results1 = Testing.attack_endpoint(url, 250, 5)
      throttled1 = Testing.count_throttled(results1)

      info("First batch: #{throttled1} throttled")
      assert throttled1 > 0, "Should hit rate limit"

      # Wait for the window to partially reset (10 seconds)
      info("Waiting 10 seconds for partial recovery...")
      Process.sleep(10_000)

      # Try again - should allow some more requests
      results2 = Testing.attack_endpoint(url, 50, 5)
      successful2 = Testing.count_successful(results2)

      info("After recovery: #{successful2} successful out of 50")

      # Should allow some requests after waiting
      assert successful2 > 0, "Should allow some requests after waiting"
    end
  end
end
