defmodule Bonfire.Federate.ActivityPub.Dance.FollowsExportImportTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Graph.Import

  test "export and import follows works between 2 instances", context do
    # Set up users
    local_user = context[:local][:user]
    remote_user = context[:remote][:user]

    # Create additional users to follow
    local_followee1 = fancy_fake_user!("LocalFollowee1")
    local_followee2 = fancy_fake_user!("LocalFollowee2")

    # Set up remote instance
    remote_followee3 =
      TestInstanceRepo.apply(fn ->
        fancy_fake_user!("RemoteFollowee3")
      end)

    assert {:ok, remote_followee3_on_local} =
             AdapterUtils.get_or_fetch_and_create_by_uri(remote_followee3[:canonical_url])

    # Create follows relationships on local instance
    Logger.metadata(action: info("create follows on local instance"))
    assert {:ok, _follow1} = Follows.follow(local_user, local_followee1[:user])
    assert {:ok, _follow2} = Follows.follow(local_user, local_followee2[:user])
    assert {:ok, _follow3} = Follows.follow(local_user, remote_followee3_on_local)

    # Verify follows exist locally
    assert Follows.following?(local_user, local_followee1[:user])
    assert Follows.following?(local_user, local_followee2[:user])
    assert Follows.following?(local_user, remote_followee3_on_local)

    # Export follows to CSV using actual controller
    Logger.metadata(action: info("export follows via controller"))
    csv_path = "/tmp/test_follows_export.csv"

    # Create a test connection and call the export endpoint
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:current_user, local_user)
      |> get("/settings/export/csv/following")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    # Write the response body to file
    File.write!(csv_path, conn.resp_body)

    # Set up remote instance
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("fetch users on remote instance"))

      local_user_ap_id = context[:local][:canonical_url]
      followee1_ap_id = local_followee1[:canonical_url]
      followee2_ap_id = local_followee2[:canonical_url]

      # assert {:ok, local_user_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_user_ap_id)
      assert {:ok, followee1_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(followee1_ap_id)

      # assert {:ok, followee2_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(followee2_ap_id)

      # Verify no follows exist initially on remote
      refute Follows.following?(remote_user, followee1_on_remote)
      # refute Follows.following?(remote_user, followee2_on_remote)

      # Import follows from CSV
      Logger.metadata(action: info("import follows from CSV"))
      # Pass user ID instead of user struct to avoid JSON encoding issues
      assert %{ok: 3} =
               Import.import_from_csv_file(:following, remote_user.id, csv_path)
               |> flood("import_result")

      # Verify follows were imported correctly
      Logger.metadata(action: info("verify imported follows"))
      assert Follows.following?(remote_user, followee1_on_remote)

      assert {:ok, followee2_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(followee2_ap_id)

      assert Follows.following?(remote_user, followee2_on_remote)

      assert Follows.following?(remote_user, remote_followee3[:user])
    end)

    # Clean up
    File.rm(csv_path)
  end
end
