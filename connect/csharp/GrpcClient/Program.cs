// A grpc-dotnet client reaching a remote gRPC service through nfltr up's
// connect: mapping. The generated client (here the standard health check)
// is unchanged; only how the channel connects changes.
//
//   dotnet run -- pipe:nfltr-ledger      Windows named pipe mapping
//   dotnet run -- unix:/path/ledger.sock unix socket mapping (Windows 10 1803+, Linux, macOS)
//   dotnet run -- localhost:50051        loopback TCP mapping
using System.IO.Pipes;
using System.Net.Sockets;
using Grpc.Health.V1;
using Grpc.Net.Client;

var endpoint = args.Length > 0 ? args[0] : "localhost:50051";

// The channel's address is the sidecar's local endpoint. Plaintext is local
// only (loopback, a user-only socket or pipe); the relay sees the bytes
// unless the server runs its own TLS (then keep https:// and the server's
// name, and connect the same way).
var handler = new SocketsHttpHandler();
string address;
if (endpoint.StartsWith("pipe:"))
{
    var name = endpoint["pipe:".Length..];
    handler.ConnectCallback = async (_, ct) =>
    {
        var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(ct);
        return pipe;
    };
    address = "http://localhost"; // the authority only; the callback connects
}
else if (endpoint.StartsWith("unix:"))
{
    var path = endpoint["unix:".Length..];
    handler.ConnectCallback = async (_, ct) =>
    {
        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        await socket.ConnectAsync(new UnixDomainSocketEndPoint(path), ct);
        return new NetworkStream(socket, ownsSocket: true);
    };
    address = "http://localhost";
}
else
{
    address = "http://" + endpoint;
}

using var channel = GrpcChannel.ForAddress(address, new GrpcChannelOptions { HttpHandler = handler });
var client = new Health.HealthClient(channel);
try
{
    var reply = await client.CheckAsync(new HealthCheckRequest(), deadline: DateTime.UtcNow.AddSeconds(10));
    Console.WriteLine(reply.Status);
    return 0;
}
catch (Grpc.Core.RpcException e) // Unavailable at once when the remote is offline
{
    Console.Error.WriteLine($"rpc failed: {e.StatusCode}: {e.Status.Detail}");
    return 1;
}
