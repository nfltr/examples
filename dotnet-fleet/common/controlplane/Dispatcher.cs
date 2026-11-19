// The control plane's dispatch, the same in app/ and with-nfltr/:
// a command to each chosen agent, over its open session (b) or by calling
// Agent.Execute on a channel to it (a), and the outcome of each.
using System.Collections.Concurrent;
using System.Diagnostics;
using FleetApi;
using Grpc.Core;
using Grpc.Net.Client;

// A channel to <agent>'s Agent service by the route `via` names. Shape (a)
// exists only where the deployment can reach an agent by name (Program.cs
// registers one); without it, dispatch is over sessions only.
delegate GrpcChannel AgentChannel(string via, string agent);

record DispatchRequest(string Via, string[] Agents, string Action, int Steps, int StepMs, int DeadlineMs, bool Fresh);

// One agent's outcome: ok (the result and every progress update arrived),
// incomplete, unavailable, deadline, or another gRPC status. Times in ms.
record Outcome(string Agent, string Status, int Progress, string Output, double Ms, double FirstProgressMs, long StartUnixMs, long EndUnixMs);

sealed class Dispatcher(Sessions sessions, AgentChannel? agentChannel = null)
{
    readonly ConcurrentDictionary<string, GrpcChannel> channels = new();

    public Task<Outcome[]> Run(DispatchRequest r) => Task.WhenAll(r.Agents.Select(a => One(r, a)));

    async Task<Outcome> One(DispatchRequest r, string agent)
    {
        var cmd = new Command { Id = Guid.NewGuid().ToString("n")[..8], Action = r.Action, Steps = r.Steps, StepMs = r.StepMs };
        DateTime? deadline = r.DeadlineMs > 0 ? DateTime.UtcNow.AddMilliseconds(r.DeadlineMs) : null;
        var start = DateTimeOffset.UtcNow;
        var sw = Stopwatch.StartNew();
        int progress = 0;
        double first = -1;
        string status = "incomplete", output = "";
        GrpcChannel? fresh = null;
        try
        {
            IAsyncEnumerable<Update> updates;
            if (r.Via == "session")
                updates = sessions.Execute(agent, cmd, deadline);
            else
            {
                // A fresh channel per call measures a new connection: a new
                // sidecar session (and E2EE handshake) each time.
                var ch = r.Fresh ? (fresh = NewChannel(r.Via, agent)) : channels.GetOrAdd(r.Via + " " + agent, _ => NewChannel(r.Via, agent));
                updates = Execute(ch, cmd, deadline);
            }
            await foreach (var u in updates)
            {
                if (u.Progress != null && progress++ == 0) first = sw.Elapsed.TotalMilliseconds;
                if (u.Result != null)
                {
                    output = u.Result.Output;
                    status = u.Result.Ok && progress == r.Steps ? "ok" : "incomplete";
                }
            }
        }
        catch (RpcException e)
        {
            status = e.StatusCode switch
            {
                StatusCode.Unavailable => "unavailable",
                StatusCode.DeadlineExceeded => "deadline",
                _ => e.StatusCode.ToString().ToLowerInvariant(),
            };
            output = e.Status.Detail;
        }
        finally
        {
            fresh?.Dispose();
        }
        return new Outcome(agent, status, progress, output, sw.Elapsed.TotalMilliseconds, first,
            start.ToUnixTimeMilliseconds(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }

    // (a) The agent by name, through whatever this deployment provides.
    GrpcChannel NewChannel(string via, string agent) =>
        agentChannel?.Invoke(via, agent) ?? throw new RpcException(new Status(StatusCode.Unimplemented,
            $"via {via}: this control plane reaches agents only over their sessions (via session)"));

    static async IAsyncEnumerable<Update> Execute(GrpcChannel ch, Command cmd, DateTime? deadline)
    {
        using var call = new Agent.AgentClient(ch).Execute(cmd, deadline: deadline);
        await foreach (var u in call.ResponseStream.ReadAllAsync())
            yield return u;
    }
}
