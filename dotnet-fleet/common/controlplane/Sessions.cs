// The control plane's Fleet.Session server, the same in app/ and
// with-nfltr/.
using System.Collections.Concurrent;
using System.Threading.Channels;
using FleetApi;
using Grpc.Core;

// (b) The agents' open sessions, by the name each sent in its Hello.
sealed class Sessions(ILogger<Sessions> log)
{
    sealed class Session(IServerStreamWriter<ControlMessage> down)
    {
        readonly SemaphoreSlim send = new(1); // one writer at a time on the response stream
        public readonly ConcurrentDictionary<string, Channel<Update>> Pending = new();

        public async Task Send(ControlMessage m)
        {
            await send.WaitAsync();
            try { await down.WriteAsync(m); }
            catch (Exception e) when (e is not RpcException) { throw new RpcException(new Status(StatusCode.Unavailable, "session lost: " + e.Message)); }
            finally { send.Release(); }
        }
    }

    readonly ConcurrentDictionary<string, Session> live = new();

    public async Task Serve(IAsyncStreamReader<AgentMessage> up, IServerStreamWriter<ControlMessage> down, ServerCallContext ctx)
    {
        if (!await up.MoveNext(ctx.CancellationToken) || up.Current.Hello is not { } hello)
            throw new RpcException(new Status(StatusCode.InvalidArgument, "the first message must be a Hello"));
        var s = new Session(down);
        live[hello.Agent] = s;
        log.LogInformation("{Agent} connected", hello.Agent);
        try
        {
            await foreach (var m in up.ReadAllAsync(ctx.CancellationToken))
                if (m.Update is { } u && s.Pending.TryGetValue(u.CommandId, out var ch))
                    ch.Writer.TryWrite(u);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or RpcException)
        {
            // the agent's session ended (agent, sidecar or relay gone)
        }
        finally
        {
            live.TryRemove(KeyValuePair.Create(hello.Agent, s)); // unless a newer session replaced it
            foreach (var ch in s.Pending.Values)
                ch.Writer.TryComplete(new RpcException(new Status(StatusCode.Unavailable, "session lost")));
            log.LogInformation("{Agent} disconnected", hello.Agent);
        }
    }

    public async IAsyncEnumerable<Update> Execute(string agent, Command cmd, DateTime? deadline)
    {
        if (!live.TryGetValue(agent, out var s))
            throw new RpcException(new Status(StatusCode.Unavailable, $"{agent} has no session"));
        var updates = Channel.CreateUnbounded<Update>();
        s.Pending[cmd.Id] = updates;
        try
        {
            await s.Send(new ControlMessage { Command = cmd });
            using var timeout = new CancellationTokenSource(deadline is { } d ? TimeSpan.FromTicks(Math.Max(0, (d - DateTime.UtcNow).Ticks)) : Timeout.InfiniteTimeSpan);
            while (true)
            {
                Update u;
                try
                {
                    u = await updates.Reader.ReadAsync(timeout.Token);
                }
                catch (OperationCanceledException)
                {
                    await s.Send(new ControlMessage { Cancel = new Cancel { CommandId = cmd.Id } });
                    throw new RpcException(new Status(StatusCode.DeadlineExceeded, "deadline exceeded; Cancel sent to the agent"));
                }
                catch (ChannelClosedException e)
                {
                    throw e.InnerException ?? e;
                }
                yield return u;
                if (u.Result != null) yield break;
            }
        }
        finally
        {
            s.Pending.TryRemove(cmd.Id, out _);
        }
    }
}

sealed class FleetService(Sessions sessions) : Fleet.FleetBase
{
    public override Task Session(IAsyncStreamReader<AgentMessage> requestStream, IServerStreamWriter<ControlMessage> responseStream, ServerCallContext context) =>
        sessions.Serve(requestStream, responseStream, context);
}
