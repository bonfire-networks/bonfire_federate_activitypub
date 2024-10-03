defmodule Bonfire.Federate.ActivityPub.Dance.UsersTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows

  @tag :test_instance
  test "can lookup actors from AP API with username, AP ID and with friendly URL",
       _context do
    # lookup 3 separate users to be sure

    remote = fancy_fake_user_on_test_instance()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:username])

    assert object.profile.name == remote[:user].profile.name

    remote = fancy_fake_user_on_test_instance()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

    assert object.profile.name == remote[:user].profile.name

    remote = fancy_fake_user_on_test_instance()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:friendly_url])

    assert object.profile.name == remote[:user].profile.name
    assert object.profile.location == remote[:user].profile.location
  end

  test "If a remote user is created, a circle is created (if doesn't already exist) and the user is added to it",
       context do
    parent_circle = Bonfire.Boundaries.Scaffold.Instance.activity_pub_circle()

    actor_url = context[:remote][:canonical_url]
    host = Bonfire.Common.URIs.base_domain(actor_url)

    {:ok, bob_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(actor_url)

    # assert that an instance circle exists
    assert {:ok, circle} = Bonfire.Boundaries.Circles.get_by_name(host, parent_circle)

    # assert that the instance circle name is the hostname of the remote instance 
    assert actor_url =~ circle.named.name
    assert host == circle.named.name

    # assert that the user is added to the instance circle
    assert Bonfire.Boundaries.Circles.is_encircled_by?(bob_remote, circle)
  end
end
