defmodule Bonfire.Federate.ActivityPub.NodeinfoAdapter do
  @behaviour Nodeinfo.Adapter
  alias Bonfire.Common.Config

  def base_url() do
    Bonfire.Common.URIs.base_url()
  end

  def gather_nodeinfo_data() do
    instance = Application.get_env(:activity_pub, :instance)

    %Nodeinfo{
      app_name: Bonfire.Application.name(),
      app_version: Bonfire.Application.version(),
      open_registrations: Bonfire.Me.Accounts.instance_is_invite_only?(),
      user_count: Bonfire.Me.Users.count(),
      node_name: Config.get([:ui, :theme, :instance_name], nil),
      node_description: Config.get([:ui, :theme, :instance_description], nil),
      federating: instance[:federating],
      app_repository: Bonfire.Application.repository()
    }
  end

end
