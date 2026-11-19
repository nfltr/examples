// The agent's business logic, the same in app/ and with-nfltr/:
// the work (progress updates, then the result) and the Agent.Execute
// server that runs it for a caller.
using System.Runtime.CompilerServices;
using FleetApi;
using Grpc.Core;

// Cancellation (a deadline, a cancelled call, a Cancel on the session)
// stops the work. A command that does not finish is logged as cancelled
// exactly once, however it stopped: its step's wait was cancelled, or the
// caller stopped reading (the enumerator is disposed and the finally runs).
sealed class Worker(string name, ILogger<Worker> log)
{
    public string Name => name;

    public async IAsyncEnumerable<Update> Run(Command c, [EnumeratorCancellation] CancellationToken ct)
    {
        log.LogInformation("command {Id} {Action}: {Steps} steps", c.Id, c.Action, c.Steps);
        var step = 0;
        var done = false;
        try
        {
            for (step = 1; step <= c.Steps; step++)
            {
                await Task.Delay(c.StepMs, ct);
                yield return new Update { CommandId = c.Id, Progress = new Progress { Step = step, Percent = step * 100 / c.Steps } };
            }
            yield return new Update { CommandId = c.Id, Result = new Result { Ok = true, Output = $"{name}: {c.Action} done" } };
            done = true;
        }
        finally
        {
            if (!done)
                log.LogWarning("command {Id} cancelled at step {Step}", c.Id, Math.Min(step, c.Steps));
        }
    }
}

// (a) Agent.Execute: a caller runs one command on this agent. A deadline
// or a cancelled call ends it quietly, with no write after the call is over.
sealed class AgentService(Worker worker) : Agent.AgentBase
{
    public override async Task Execute(Command request, IServerStreamWriter<Update> stream, ServerCallContext context)
    {
        var ct = context.CancellationToken;
        try
        {
            await foreach (var u in worker.Run(request, ct))
            {
                if (ct.IsCancellationRequested)
                    return;
                await stream.WriteAsync(u, ct);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (InvalidOperationException)
        {
            // The call is over: on a deadline ASP.NET Core completes the
            // response before it cancels ct, so a write in between fails
            // ("Writing is not allowed after writer was completed"). Writes
            // here are sequential, so nothing else throws this.
        }
    }
}
