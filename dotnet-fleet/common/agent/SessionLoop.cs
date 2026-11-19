// (b) The agent-initiated Fleet.Session, the same in app/ and
// with-nfltr/: Hello, then commands down and updates up on one stream; the
// application's own reconnect loop with backoff. Only the channel it is
// given differs (Program.cs).
using System.Collections.Concurrent;
using FleetApi;
using Grpc.Core;
using Grpc.Net.Client;

sealed class SessionLoop(Worker worker, GrpcChannel channel, ILogger<SessionLoop> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        var client = new Fleet.FleetClient(channel);
        var backoff = TimeSpan.FromSeconds(1);
        while (!stop.IsCancellationRequested)
        {
            using var session = CancellationTokenSource.CreateLinkedTokenSource(stop);
            try
            {
                using var call = client.Session(cancellationToken: session.Token);
                var send = new SemaphoreSlim(1); // one writer at a time on the request stream
                async Task Send(AgentMessage m)
                {
                    await send.WaitAsync(session.Token);
                    try { await call.RequestStream.WriteAsync(m); }
                    finally { send.Release(); }
                }
                await Send(new AgentMessage { Hello = new Hello { Agent = worker.Name } });
                log.LogInformation("session open");
                backoff = TimeSpan.FromSeconds(1);
                var running = new ConcurrentDictionary<string, CancellationTokenSource>();
                await foreach (var m in call.ResponseStream.ReadAllAsync(session.Token))
                {
                    if (m.Command is { } c)
                    {
                        var cts = CancellationTokenSource.CreateLinkedTokenSource(session.Token);
                        running[c.Id] = cts;
                        _ = Task.Run(async () =>
                        {
                            try
                            {
                                await foreach (var u in worker.Run(c, cts.Token))
                                    await Send(new AgentMessage { Update = u });
                            }
                            catch (Exception e) when (e is OperationCanceledException or RpcException or InvalidOperationException)
                            {
                                // cancelled, or the session ended under it
                            }
                            finally
                            {
                                running.TryRemove(c.Id, out _);
                            }
                        });
                    }
                    else if (m.Cancel is { } x && running.TryGetValue(x.CommandId, out var cts))
                    {
                        cts.Cancel();
                    }
                }
                log.LogWarning("session ended by the control plane");
            }
            catch (Exception e) when (!stop.IsCancellationRequested)
            {
                log.LogWarning("session: {Error}", e is RpcException r ? $"{r.StatusCode}: {r.Status.Detail}" : e.Message);
            }
            finally
            {
                session.Cancel(); // stops this session's running commands
            }
            await Task.Delay(backoff, stop);
            backoff = TimeSpan.FromSeconds(Math.Min(backoff.TotalSeconds * 2, 5));
        }
    }
}
