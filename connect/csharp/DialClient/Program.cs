// One session to a remote service through `nfltr cat pipe`, from .NET.
//
//   dotnet run -- home/db [payload]
//
// The session is the child's stdin/stdout as binary streams (never the
// TextReader/TextWriter wrappers); stderr is JSON lines, read concurrently
// so a full pipe never blocks dial. On Windows the child runs in a Job Object
// with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: if this process dies, Windows
// kills dial with it (dial --exit-with-parent covers the same from its side).
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

var target = args.Length > 0 ? args[0] : throw new ArgumentException("usage: DialClient <agent>/<service> [payload]");
var payload = Encoding.UTF8.GetBytes(args.Length > 1 ? args[1] : "hello");

var psi = new ProcessStartInfo(Environment.GetEnvironmentVariable("NFLTR") ?? "nfltr")
{
    RedirectStandardInput = true,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
    UseShellExecute = false,
};
psi.ArgumentList.Add("cat");
psi.ArgumentList.Add("pipe");
psi.ArgumentList.Add(target);
psi.ArgumentList.Add("--exit-with-parent");
// On a machine enrolled in an organisation (nfltr org join) the session is
// end-to-end encrypted in organisation mode; NFLTR_PLAIN=1 opens it plain
// on purpose (cat pipe --plain).
if (Environment.GetEnvironmentVariable("NFLTR_PLAIN") == "1")
{
    psi.ArgumentList.Add("--plain");
}

using var proc = Process.Start(psi)!;
if (OperatingSystem.IsWindows()) Job.KillOnClose(proc);

var events = Task.Run(async () =>
{
    var list = new List<JsonElement>();
    while (await proc.StandardError.ReadLineAsync() is { } line)
        list.Add(JsonDocument.Parse(line).RootElement.Clone());
    return list;
});

var stdin = proc.StandardInput.BaseStream;
await stdin.WriteAsync(payload);
await stdin.FlushAsync();
stdin.Close(); // half close: the remote reads EOF, its answer still comes

using var answer = new MemoryStream();
await proc.StandardOutput.BaseStream.CopyToAsync(answer);
await proc.WaitForExitAsync();

foreach (var e in await events) Console.Error.WriteLine($"event: {e}");
Console.WriteLine(Encoding.UTF8.GetString(answer.ToArray()));
return proc.ExitCode; // 0 ok, 2 auth, 3 not_found, 4 refused, 5 unreachable, 6 reset, 8 parent_gone

static class Job
{
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    static IntPtr handle; // kept open for this process's life; closing it kills the job

    public static void KillOnClose(Process p)
    {
        handle = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(info);
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, ptr, (uint)size))
                throw new System.ComponentModel.Win32Exception();
        }
        finally { Marshal.FreeHGlobal(ptr); }
        if (!AssignProcessToJobObject(handle, p.Handle))
            throw new System.ComponentModel.Win32Exception();
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attrs, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
}
