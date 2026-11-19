// Optional, new with the sidecar: shape (a), a channel to one agent by
// name. Configuration (appsettings.json, environment):
//   Fleet:Agents:<name>:Mapping  the sidecar's local endpoint for <name>.<name>/execute
//   Fleet:Agents:<name>:Plain    true: `nfltr cat pipe --plain` (a service not end-to-end encrypted)
//   Fleet:Nfltr                  the nfltr binary (default: nfltr on PATH)
using Grpc.Core;

static class AgentChannels
{
    public static AgentChannel For(IConfiguration cfg) => (via, agent) => via switch
    {
        "mapping" => SidecarChannel.For(cfg[$"Fleet:Agents:{agent}:Mapping"] ?? throw new RpcException(new Status(StatusCode.NotFound, $"no mapping for {agent}"))),
        "dial" => DialChannel.For($"{agent}.{agent}/execute", cfg.GetValue<bool>($"Fleet:Agents:{agent}:Plain"), cfg["Fleet:Nfltr"] ?? "nfltr"),
        _ => throw new RpcException(new Status(StatusCode.InvalidArgument, $"via {via}: want mapping, dial or session")),
    };
}
