defmodule Bonfire.Federate.ActivityPub.ActivityFallbackTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  # alias Bonfire.Posts

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      # %{url: "https://mocked.local/relation/27005"} ->

      # NOTE: already mocked in AP lib

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "" do
    test "object with Custom Type is recorded as APActivity" do
      type = "CustomType"

      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("type", type)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_map(activity.json["object"])
      assert activity.json["object"]["type"] == type
      assert is_binary(activity.json["object"]["content"])

      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id)
    end

    test "Question object is recorded as APActivity, and doesn't create duplicates" do
      data =
        "../fixtures/poll_attachment.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_list(activity.json["oneOf"])
      assert activity.json["type"] == "Question"
      assert is_binary(activity.json["content"])

      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id)

      # Second fetch of the same data
      assert {:ok, activity2} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      # Should return the same activity, not create a duplicate
      assert activity.id == activity2.id
      assert activity.json["id"] == activity2.json["id"]
    end

    test "non-public object with Custom Type is recorded as private APActivity" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      type = "CustomType"

      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("type", type)
        |> Map.put("to", recipient_actor)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)
      # |> debug("handled")

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_map(activity.json["object"])
      assert activity.json["object"]["type"] == type
      assert is_binary(activity.json["object"]["content"])

      assert {:error, _} = Bonfire.Social.Objects.read(activity.id)
      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id, current_user: recipient)
    end

    test "Arrive activity is recorded as public APActivity with processed location" do
      data =
        "../fixtures/place-arrive.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      location_id = "https://mocked.local/relation/27005"

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert activity.json["type"] == "Arrive"
      assert is_map(debug(activity.json["location"], "location"))
      assert activity.json["location"]["type"] == ["Place", "geojson:Feature"]

      # assert activity.json["location"]["name"] == "CERN - Site de Meyrin" # name removed in favour or pointing to the location object
      assert location_id == activity.json["location"]["id"]
      assert location_pointer_id = activity.json["location"]["pointer_id"]

      # Should be public since "to" contains "as:Public" collection
      assert {:ok, arrive_pointer} =
               Bonfire.Social.Objects.read(activity.id)
               |> repo().maybe_preload(:activity)

      # Check if the nested location object was processed and fetched/created

      assert {:ok, location_bonfire_object} =
               Bonfire.Geolocate.Geolocations.one(id: location_pointer_id)

      # assert {:ok, _location_bonfire_object} = Bonfire.Social.Objects.read(location_pointer_id) # FIXME

      # Test the AP pointer preloading functionality      
      loaded_activity =
        Bonfire.Social.Activities.activity_preloads(
          arrive_pointer,
          preload: [:with_subject]
        )

      loaded_activity =
        Bonfire.Social.Activities.activity_preloads(
          loaded_activity,
          current_user: e(arrive_pointer, :activity, :subject, nil)
        )

      # Check if the location was enriched with the loaded object
      location_object = loaded_activity.json["location"]["pointer"]
      assert is_map(location_object)
      assert location_object.id == activity.json["location"]["pointer_id"]
      # assert location_object.json["name"] == "CERN - Site de Meyrin"
      assert location_object.name == "CERN - Site de Meyrin"

      # Try to get the location object from ActivityPub.Object
      case ActivityPub.Object.get_cached(ap_id: location_id) do
        {:ok, location_object} ->
          # Location was processed and stored as a separate object
          assert location_object.data["type"] == ["Place", "geojson:Feature"]
          assert location_object.data["name"] == "CERN - Site de Meyrin"

        # assert location_pointer_id == location_object.pointer_id
        # NOTE: is the pointer_id on the Create activity instead of the object? 

        {:error, :not_found} ->
          flunk("Location object not found via AP ID?")

        other ->
          flunk("Unexpected result when looking for location object: #{inspect(other)}")
      end

      #  case ActivityPub.Object.get_cached(pointer: location_pointer_id) do
      #   {:ok, location_object} ->
      #     # Location was processed and stored as a separate object
      #     assert location_object.data["type"] == ["Place", "geojson:Feature"]
      #     assert location_object.data["name"] == "CERN - Site de Meyrin"

      #   {:error, :not_found} -> # FIXME!
      #     flunk("Location object not found via pointer?")

      #   other ->
      #     flunk("Unexpected result when looking for location object: #{inspect(other)}")
      # end
    end
  end
end
