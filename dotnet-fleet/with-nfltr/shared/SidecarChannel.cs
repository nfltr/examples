// How the fleet's gRPC channels reach the nfltr connect sidecar: a
// channel's target is a local endpoint of the sidecar. Stubs, calls, deadlines and streaming stay as they were.
using System.IO.Pipes;
using System.Net.Sockets;
using Grpc.Net.Client;

static class SidecarChannel
{
    // endpoint: "pipe:<name>" (Windows named pipe), "unix:<path>" (unix
    // socket: Linux, macOS, Windows 10 1803+) or "host:port" (loopback TCP).
    public static GrpcChannel For(string endpoint)
    {
        var handler = new SocketsHttpHandler();
        if (endpoint.StartsWith("pipe:"))
        {
            var name = endpoint["pipe:".Length..];
            handler.ConnectCallback = async (_, ct) =>
            {
                var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(ct);
                return pipe;
            };
            return Channel("http://localhost", handler); // the authority only; the callback connects
        }
        if (endpoint.StartsWith("unix:"))
        {
            var path = endpoint["unix:".Length..];
            handler.ConnectCallback = async (_, ct) =>
            {
                var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                try
                {
                    await socket.ConnectAsync(new UnixDomainSocketEndPoint(path), ct);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
                return new NetworkStream(socket, ownsSocket: true);
            };
            return Channel("http://localhost", handler);
        }
        return Channel("http://" + endpoint, handler);
    }

    internal static GrpcChannel Channel(string address, SocketsHttpHandler handler) =>
        GrpcChannel.ForAddress(address, new GrpcChannelOptions { HttpHandler = handler });
}
