// How an agent reaches the control plane: a TLS channel
// to its public endpoint that trusts the fleet's private CA (not the
// machine's store) and checks the name the certificate was issued for;
// HTTP/2 keepalive pings, because a NAT or firewall drops an idle
// connection without telling either side; and a connect timeout, because a
// connect to an unreachable host waits out the kernel's SYN retries; and a
// CONNECT through the customer site's HTTP proxy where that is the only way
// out (grpc-dotnet's own connection logic uses neither HTTPS_PROXY nor the
// handler's Proxy, so the tunnel is opened here). The
// session's reconnect loop with backoff is common/agent/SessionLoop.cs.
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using Grpc.Net.Client;

static class ControlPlaneChannel
{
    public static GrpcChannel For(IConfiguration cfg)
    {
        var url = cfg["Url"] ?? throw new ArgumentException("ControlPlane:Url is required");
        var ca = new X509Certificate2(cfg["CaCertificate"] ?? throw new ArgumentException("ControlPlane:CaCertificate is required")); // PEM or DER
        var serverName = cfg["ServerName"] is { Length: > 0 } n ? n : new Uri(url).Host;
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = cfg.GetValue("ConnectTimeout", TimeSpan.FromSeconds(10)),
            KeepAlivePingDelay = cfg.GetValue("KeepAlivePingDelay", TimeSpan.FromSeconds(20)),
            KeepAlivePingTimeout = cfg.GetValue("KeepAlivePingTimeout", TimeSpan.FromSeconds(10)),
            KeepAlivePingPolicy = HttpKeepAlivePingPolicy.Always,
            PooledConnectionIdleTimeout = Timeout.InfiniteTimeSpan,
            EnableMultipleHttp2Connections = true,
            SslOptions = new SslClientAuthenticationOptions
            {
                TargetHost = serverName,
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                RemoteCertificateValidationCallback = (_, cert, _, _) => Trusted(cert, ca, serverName),
            },
        };
        if (cfg["Proxy"] is { Length: > 0 } proxy) // http://host:port
            handler.ConnectCallback = (ctx, ct) => ThroughProxy(new Uri(proxy), ctx.DnsEndPoint, ct);
        return GrpcChannel.ForAddress(url, new GrpcChannelOptions { HttpHandler = handler });
    }

    // A TCP connection to target through the proxy's CONNECT; TLS runs inside it.
    static async ValueTask<Stream> ThroughProxy(Uri proxy, DnsEndPoint target, CancellationToken ct)
    {
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(proxy.Host, proxy.Port, ct);
            var stream = new NetworkStream(socket, ownsSocket: true);
            var hostPort = $"{target.Host}:{target.Port}";
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"CONNECT {hostPort} HTTP/1.1\r\nHost: {hostPort}\r\n\r\n"), ct);
            // The answer, up to its blank line, a byte at a time: what follows is the server's.
            var head = new StringBuilder();
            var b = new byte[1];
            while (!head.ToString().EndsWith("\r\n\r\n"))
            {
                if (await stream.ReadAsync(b, ct) == 0) throw new IOException("the proxy closed the connection");
                head.Append((char)b[0]);
            }
            var status = head.ToString().Split("\r\n")[0];
            if (status.Split(' ') is not [_, "200", ..]) throw new IOException($"proxy: {status}");
            return stream;
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    // The chain must end at the fleet's CA and the certificate must name
    // serverName; the platform's own name check is replaced because the URL
    // may address the control plane by another name or an IP address.
    static bool Trusted(X509Certificate? presented, X509Certificate2 ca, string serverName)
    {
        if (presented is null) return false;
        using var cert = new X509Certificate2(presented);
        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(ca);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck; // a private CA without a CRL endpoint
        return chain.Build(cert) && cert.MatchesHostname(serverName);
    }
}
