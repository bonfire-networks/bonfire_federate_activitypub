defmodule Bonfire.Federate.ActivityPub.NodeinfoAdapter do
  @behaviour Nodeinfo.Adapter
  alias Bonfire.Common.Config

  def base_url() do
    Bonfire.Common.URIs.base_url()
  end

  def gather_nodeinfo_data() do
    app_name = Bonfire.Application.name()
    instance = Application.get_env(:activity_pub, :instance)

    %Nodeinfo{
      app_name: app_name,
      app_version: Bonfire.Application.version(),
      open_registrations: !Bonfire.Me.Accounts.instance_is_invite_only?(),
      user_count: Bonfire.Me.Users.maybe_count(),
      node_name: Config.get([:ui, :theme, :instance_name], nil) || "An instance of #{app_name}",
      node_description: Config.get([:ui, :theme, :instance_description], nil),
      federating: ActivityPub.Config.federating?(),
      app_repository: Bonfire.Application.repository()
    }
  end
end
