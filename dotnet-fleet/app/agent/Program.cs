// Edge agent: a worker service that
// keeps one Fleet.Session open to the control plane's public TLS endpoint.
// It has no server: behind NAT nothing can reach it, so commands arrive
// only over the session it opens.
//
//   Agent --Name edge-1 [--ControlPlane:Url https://controlplane.fleet.example:8443]
//
// ControlPlane (appsettings.json): Url, CaCertificate (the fleet's private
// CA), ServerName (the name on the control plane's certificate when the
// URL's host differs), the HTTP/2 keepalive and connect timeout.
using Grpc.Net.Client;

var builder = Host.CreateApplicationBuilder(args);
var name = builder.Configuration["Name"] ?? throw new ArgumentException("--Name is required");
builder.Services.AddSingleton(sp => new Worker(name, sp.GetRequiredService<ILogger<Worker>>()));
builder.Services.AddSingleton<GrpcChannel>(ControlPlaneChannel.For(builder.Configuration.GetSection("ControlPlane")));
builder.Services.AddHostedService<SessionLoop>();
builder.Build().Run();
