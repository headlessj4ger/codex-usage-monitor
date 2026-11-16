using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Management;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;

namespace CodexUsageMonitor;

static class Program
{
    internal static readonly string Base = AppContext.BaseDirectory;
    internal static string Executable => Environment.ProcessPath!;
    internal static string Node => Path.Combine(Base, "runtime", "node.exe");
    internal static string Version => JsonNode.Parse(File.ReadAllText(Path.Combine(Base, "version.json")))!["version"]!.GetValue<string>();

    [STAThread]
    static int Main(string[] args)
    {
        if (Console.IsOutputRedirected) Console.OutputEncoding = new UTF8Encoding(false);
        string command = args.FirstOrDefault()?.TrimStart('-').ToLowerInvariant() ?? "start";
        try
        {
            if (command == "sample-processes") { ProcessSampler.Write(); return 0; }
            if (command == "doctor") { Doctor(); return 0; }
            if (command is not ("start" or "main" or "mini" or "tray" or "demo" or "self-test"))
                throw new ArgumentException("Unknown command: " + command);
            var user = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
            var channel = "CodexUsageMonitor.Native." + user + (command == "demo" ? ".Demo" : command == "self-test" ? "." + Environment.ProcessId : "");
            using var mutex = new Mutex(true, @"Local\" + channel, out bool owner);
            if (!owner)
            {
                using var pipe = new NamedPipeClientStream(".", channel, PipeDirection.Out);
                pipe.Connect(10000);
                using var writer = new StreamWriter(pipe);
                writer.WriteLine(command);
                return 0;
            }

            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            using var cancellation = new CancellationTokenSource();
            var root = args.Skip(1).FirstOrDefault();
            if (command == "self-test" && string.IsNullOrWhiteSpace(root)) throw new ArgumentException("Self-test requires an isolated data directory.");
            var monitor = new MonitorApp(app, new Storage(root, create: command != "demo"), command);
            var listener = Listen(channel, monitor, cancellation.Token);
            try { return app.Run(); }
            finally { cancellation.Cancel(); monitor.Dispose(); }
        }
        catch (Exception error)
        {
            if (Console.IsErrorRedirected) Console.Error.WriteLine(error);
            if (command is not ("doctor" or "sample-processes" or "self-test"))
                MessageBox.Show(error.Message, "Codex 用量透视", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }

    static async Task Listen(string name, MonitorApp monitor, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                using var pipe = new NamedPipeServerStream(name, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(token).ConfigureAwait(false);
                using var reader = new StreamReader(pipe);
                var command = await reader.ReadLineAsync(token).ConfigureAwait(false);
                if (command is "start" or "main" or "mini" or "tray" or "demo")
                    await monitor.Dispatcher.InvokeAsync(() => monitor.Show(command));
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { await monitor.Dispatcher.InvokeAsync(() => monitor.Error(error)); }
    }

    static void Doctor()
    {
        var storage = new Storage(null, create: false);
        var psi = new ProcessStartInfo(Node) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        psi.ArgumentList.Add("--no-warnings");
        psi.ArgumentList.Add(Path.Combine(Base, "runtime-check.cjs"));
        using var node = Process.Start(psi)!;
        var runtime = node.StandardOutput.ReadToEnd().Trim();
        node.WaitForExit();
        if (node.ExitCode != 0) throw new InvalidOperationException("Node SQLite check failed.");
        Console.WriteLine(JsonSerializer.Serialize(new { version = Version, ready = true, runtime, dataDirectory = storage.Data, codexHome = storage.CodexHome, codexFound = Directory.Exists(storage.CodexHome) }));
    }
}

sealed class Storage
{
    public string Data { get; }
    public string SettingsPath { get; }
    public string CodexHome { get; }
    public bool External { get; }
    public JsonObject Settings { get; }
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "CodexUsageMonitor";

    public Storage(string? dataRoot, bool create = true)
    {
        dataRoot ??= Environment.GetEnvironmentVariable("CODEX_MONITOR_DATA");
        External = !string.IsNullOrEmpty(dataRoot);
        if (External && !Path.IsPathFullyQualified(dataRoot!)) throw new ArgumentException("CODEX_MONITOR_DATA must be an absolute directory path.");
        Data = External ? Path.GetFullPath(dataRoot!) : Path.Combine(Program.Base, "data");
        SettingsPath = Path.Combine(External ? Data : Program.Base, "settings.json");
        CodexHome = Path.GetFullPath(Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } home
            ? home : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));
        if (create) Directory.CreateDirectory(Data);
        try { Settings = File.Exists(SettingsPath) ? JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? new() : new(); }
        catch (JsonException) { Settings = new(); }
    }

    public T Get<T>(string name, T fallback) => Settings[name] is JsonValue v && v.TryGetValue<T>(out var value) ? value : fallback;
    public void Set<T>(string name, T value) { Settings[name] = JsonSerializer.SerializeToNode(value); Save(); }
    void Save()
    {
        var temp = SettingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temp, Settings.ToJsonString(new JsonSerializerOptions { WriteIndented = true })); File.Move(temp, SettingsPath, true); }
        finally { File.Delete(temp); }
    }
    public bool Autostart
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            var command = key?.GetValue(RunName) as string;
            return command?.StartsWith("\"" + Program.Executable + "\" tray", StringComparison.OrdinalIgnoreCase) == true;
        }
    }
    public void SetAutostart(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled)
        {
            var root = External ? " \"" + Path.TrimEndingDirectorySeparator(Data) + "\"" : "";
            key.SetValue(RunName, "\"" + Program.Executable + "\" tray" + root);
        }
        else key.DeleteValue(RunName, false);
    }
}

static class ProcessSampler
{
    static readonly Regex ThreadMarker = new("""--(?:thread|session)[-_]id(?:=|\s+)["']?([0-9a-f-]{36})|[\\/]\.codex[\\/]node_repl[\\/]([0-9a-f-]{36})(?:[\\/]|["'\s]|$)""", RegexOptions.IgnoreCase);

    public static void Write()
    {
        const string query = "SELECT ProcessId,ParentProcessId,Name,CreationDate,WorkingSetSize,KernelModeTime,UserModeTime,CommandLine FROM Win32_Process";
        using var searcher = new ManagementObjectSearcher(@"root\cimv2", query);
        using var processes = searcher.Get();
        var rows = new List<object>();
        foreach (ManagementObject row in processes)
        {
            using var process = row;
            object? Get(string name) => process[name];
            var raw = Get("CreationDate") as string;
            string? created = null;
            if (raw is { Length: >= 25 } && DateTime.TryParseExact(raw[..21], "yyyyMMddHHmmss.ffffff", CultureInfo.InvariantCulture, DateTimeStyles.None, out var time)
                && int.TryParse(raw[21..25], out var offset) && Math.Abs(offset) <= 840)
                created = new DateTimeOffset(time, TimeSpan.FromMinutes(offset)).UtcDateTime.ToString("O");
            var marker = ThreadMarker.Match(Get("CommandLine") as string ?? "");
            var candidate = marker.Groups[1].Success ? marker.Groups[1].Value : marker.Groups[2].Value;
            rows.Add(new { pid = Convert.ToInt32(Get("ProcessId")), ppid = Convert.ToInt32(Get("ParentProcessId")),
                name = Get("Name") as string, created, memory = Convert.ToDouble(Get("WorkingSetSize")),
                cpu = (Convert.ToDouble(Get("KernelModeTime")) + Convert.ToDouble(Get("UserModeTime"))) / 1e7,
                command = Guid.TryParseExact(candidate,"D",out _) ? "--thread-id " + candidate : "" });
        }
        Console.WriteLine(JsonSerializer.Serialize(rows));
    }
}
