defmodule Bonfire.Federate.ActivityPub.NodeinfoApplicationActorTest do
  @moduledoc """
  FEP-2677: our nodeinfo's link list names the actor that signs for the instance, as `ActivityPub.Instances.scrape_nodeinfo/2` looks for it on other servers, so a server reading ours learns it without asking anything else.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: true
  @moduletag :federation

  test "the nodeinfo link list names our service actor" do
    {:ok, service_actor} = ActivityPub.Utils.service_actor()

    links =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/nodeinfo")
      |> json_response(200)
      |> Map.fetch!("links")

    # the positive first: the schema links are what the document is for, and still there
    assert Enum.any?(links, &(&1["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.0"))

    assert Enum.any?(
             links,
             &(&1["rel"] == "https://www.w3.org/ns/activitystreams#Application" and
                 &1["href"] == service_actor.ap_id)
           ),
           "the link list should name the service actor, got #{inspect(links)}"
  end
end
