// Edge agent on the nfltr connect sidecar: keeps one Fleet.Session open to
// the control plane through the sidecar's local endpoint, and serves
// Agent.Execute on loopback, which the sidecar publishes as <name>/execute
// (no inbound port: the sidecar dials out).
//
//   Agent --Name edge-1 [--ControlPlane unix:/run/nfltr/fleet.sock]
//         [--Sidecar /etc/fleet/edge-1.yaml] [--Nfltr /opt/nfltr/nfltr]
//
// ControlPlane: the sidecar's endpoint for controlplane/fleet: unix:<path>,
// pipe:<name> (Windows) or 127.0.0.1:<port>. Execute's loopback listener:
// appsettings.json ("Kestrel"). --Sidecar: this process starts and owns
// its sidecar (OwnedSidecar.cs); without it the service manager runs the
// sidecar beside this process.
using Grpc.Net.Client;

var builder = WebApplication.CreateBuilder(args);
var name = builder.Configuration["Name"] ?? throw new ArgumentException("--Name is required");
builder.Services.AddSingleton(sp => new Worker(name, sp.GetRequiredService<ILogger<Worker>>()));
builder.Services.AddSingleton<GrpcChannel>(SidecarChannel.For(builder.Configuration["ControlPlane"] ?? throw new ArgumentException("--ControlPlane is required")));
builder.Services.AddHostedService<SessionLoop>();
builder.Services.AddGrpc();
var app = builder.Build();
app.MapGrpcService<AgentService>();
if (builder.Configuration["Sidecar"] is { } file)
    OwnedSidecar.Start(app, file, builder.Configuration["Nfltr"] ?? "nfltr");
app.Run();
