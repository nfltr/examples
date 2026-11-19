// Optional: the agent starts `nfltr up -c <file>` itself and owns it. It
// dies with this process (--exit-with-parent, and a Job Object on Windows);
// when it exits, this process stops too and the service manager restarts
// both. Call Start from the main thread, which lives as long as the
// process: Linux delivers nfltr's parent-death signal when the *thread*
// that started it exits.
using System.Diagnostics;

static class OwnedSidecar
{
    public static void Start(WebApplication app, string file, string nfltr)
    {
        var psi = new ProcessStartInfo(nfltr) { UseShellExecute = false };
        foreach (var a in new[] { "up", "-c", file, "--exit-with-parent", "--log-format", "json" }) psi.ArgumentList.Add(a);
        var sidecar = Process.Start(psi)!; // stdout/stderr: this process's, so one log has both
        if (OperatingSystem.IsWindows()) Job.KillOnClose(sidecar);
        sidecar.EnableRaisingEvents = true;
        sidecar.Exited += (_, _) =>
        {
            app.Logger.LogError("sidecar exited with {Code}", sidecar.ExitCode);
            Environment.ExitCode = 1;
            app.Lifetime.StopApplication();
        };
    }
}
