// Optional: reach an agent's service with no connect: mapping, one
// `nfltr cat pipe` child process per HTTP/2 connection (a large or changing fleet).
using System.Diagnostics;
using Grpc.Net.Client;

static class DialChannel
{
    // Reach <agent>/<service> with no mapping configured: every HTTP/2
    // connection of the channel is one `nfltr cat pipe` child whose stdin/stdout
    // are the connection. plain: a plain session (--plain), for a service not
    // end-to-end encrypted; otherwise an enrolled machine's sessions are in
    // organisation mode.
    public static GrpcChannel For(string target, bool plain, string nfltr)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = (_, _) => ValueTask.FromResult<Stream>(DialStream.Start(nfltr, target, plain)),
        };
        return SidecarChannel.Channel("http://localhost", handler);
    }
}

// The stdin/stdout of one `nfltr cat pipe` process as a duplex stream. stderr
// is JSON lines (open, close, error) and is read so it never blocks dial.
// The exit code is typed: 3 not_found, 4 refused, 5 unreachable, 7 not
// in organisation mode, 10 e2ee_client_refused, ...
// (https://nfltr.xyz/docs); here a failed
// open surfaces as the gRPC call's UNAVAILABLE.
sealed class DialStream : Stream
{
    readonly Process proc;
    readonly Stream read, write;

    DialStream(Process proc)
    {
        this.proc = proc;
        read = proc.StandardOutput.BaseStream;
        write = proc.StandardInput.BaseStream;
    }

    public static DialStream Start(string nfltr, string target, bool plain)
    {
        var psi = new ProcessStartInfo(nfltr)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var a in new[] { "cat", "pipe", target, "--exit-with-parent" }) psi.ArgumentList.Add(a);
        if (plain) psi.ArgumentList.Add("--plain");
        var proc = Process.Start(psi)!;
        if (OperatingSystem.IsWindows()) Job.KillOnClose(proc);
        proc.ErrorDataReceived += (_, e) => { if (e.Data is { } line) Console.Error.WriteLine($"dial {target}: {line}"); };
        proc.BeginErrorReadLine();
        return new DialStream(proc);
    }

    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override int Read(byte[] buffer, int offset, int count) => read.Read(buffer, offset, count);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => read.ReadAsync(buffer, ct);
    public override void Write(byte[] buffer, int offset, int count) => write.Write(buffer, offset, count);
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) => write.WriteAsync(buffer, ct);
    public override void Flush() => write.Flush();
    public override Task FlushAsync(CancellationToken ct) => write.FlushAsync(ct);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try { write.Dispose(); } catch (IOException) { } // stdin EOF: dial half-closes and exits
            try { if (!proc.WaitForExit(2000)) proc.Kill(); } catch (InvalidOperationException) { }
            proc.Dispose();
        }
        base.Dispose(disposing);
    }

    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}
