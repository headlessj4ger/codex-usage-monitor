using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace CodexUsageMonitor;

sealed class CollectorClient(Storage storage) : IDisposable
{
    Process? process;
    public bool Running => process is { HasExited: false };
    public readonly ConcurrentQueue<(bool Error, string Line)> Messages = new();

    public void Start(int interval)
    {
        if (Running) return;
        process?.Dispose();
        Messages.Clear();
        var start = new ProcessStartInfo(Program.Node) {
            WorkingDirectory = Program.Base, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false)
        };
        foreach (var arg in new[] {"--no-warnings", Path.Combine(Program.Base,"collector.cjs"), "--interval", interval.ToString(),
            "--data", storage.Data, "--home", storage.CodexHome, "--process-sampler", Program.Executable}) start.ArgumentList.Add(arg);
        var child = new Process { StartInfo = start };
        child.OutputDataReceived += (_, e) => { if (e.Data != null && process == child) Messages.Enqueue((false, e.Data)); };
        child.ErrorDataReceived += (_, e) => { if (e.Data != null && process == child) Messages.Enqueue((true, e.Data)); };
        process = child;
        try { child.Start(); }
        catch { process = null; child.Dispose(); throw; }
        child.BeginOutputReadLine();
        child.BeginErrorReadLine();
    }
    public void Send(string action, int interval, string id = "", string turn = "")
    {
        if (!Running) return;
        process!.StandardInput.WriteLine(JsonSerializer.Serialize(new { action, id, turn_id = turn, refresh_seconds = interval }));
        process.StandardInput.Flush();
    }
    public void Dispose()
    {
        if (process == null) return;
        try {
            if (Running) {
                try { Send("stop", 0); } catch (IOException) { }
                if (!process.WaitForExit(1800)) process.Kill(entireProcessTree: true);
            }
        } finally { process.Dispose(); process = null; }
    }
}
