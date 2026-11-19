// Control plane. Serves Fleet.Session (shape b: agents connect in) and
// dispatches commands to agents over their open sessions.
//
//   ControlPlane serve      Fleet and POST /dispatch on the endpoints of
//                           appsettings.json ("Kestrel")
//   ControlPlane dispatch --via session --agents edge-1,edge-2
//                         [--steps 5] [--step-ms 100] [--deadline-ms 0]
//                         [--expect ok] [--retry-s 0]
//   ControlPlane bench --via session --agents edge-1,edge-3 [--n 50]
//
// Kestrel's endpoints come from appsettings.json: Fleet, gRPC over TLS on a
// public port with the control plane's certificate and HTTP/2 keepalive;
// Admin, the operator API on loopback.
if (args.Length > 0 && args[0] is "dispatch" or "bench")
    return await Cli.Run(args[0], new ConfigurationBuilder().AddCommandLine(args[1..]).Build());

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddGrpc();
builder.Services.AddSingleton<Sessions>();
builder.Services.AddSingleton<Dispatcher>();
var app = builder.Build();
app.MapGrpcService<FleetService>();
app.MapPost("/dispatch", (DispatchRequest r, Dispatcher d) => d.Run(r));
app.Run();
return 0;
