using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TerminalSuggestions
{
    // One long-lived `hdc shell` per enhanced session. hdc requires a TTY for
    // interactive stdin, so stdin is a host PTY while stdout/stderr stay pipes.
    // Every command runs in a new `setsid sh -c` child: the channel is reused,
    // but variables, aliases and shell options still cannot leak between
    // commands. Non-Unix hosts and failed handshakes fall back to the
    // per-command HdcShellProcess.Run path.
    public sealed class HdcShellSession : IDisposable
    {
        // Keep well below the interactive line editor's limit. Longer commands
        // use the per-command RPC path instead of risking truncation.
        public const int MaxScriptLength = 3000;

        private sealed class Chunk { public string Text; public bool Error; }

        [DllImport("libc", SetLastError = true)] private static extern int posix_openpt(int flags);
        [DllImport("libc", SetLastError = true)] private static extern int grantpt(int fd);
        [DllImport("libc", SetLastError = true)] private static extern int unlockpt(int fd);
        [DllImport("libc", SetLastError = true)] private static extern IntPtr ptsname(int fd);
        [DllImport("libc", SetLastError = true)] private static extern int close(int fd);
        [DllImport("libc", SetLastError = true)] private static extern IntPtr read(int fd, byte[] buffer, IntPtr count);
        [DllImport("libc", SetLastError = true)] private static extern IntPtr write(int fd, byte[] buffer, IntPtr count);

        private readonly string application, serial, marker;
        private Process process;
        private int master = -1;
        private volatile ConcurrentQueue<Chunk> active;
        private readonly object gate = new object();
        private volatile bool disposed, faulted;

        public bool Alive
        {
            get
            {
                try { return !disposed && !faulted && process != null && !process.HasExited && master >= 0; }
                catch { return false; }
            }
        }

        private HdcShellSession(string application, string serial, string marker)
        {
            this.application = application;
            this.serial = serial;
            this.marker = marker;
        }

        public static bool TryStart(string application, string serial, string marker, out HdcShellSession session)
        {
            session = null;
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Linux) &&
                !RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return false;
            var candidate = new HdcShellSession(application, serial, marker);
            try
            {
                if (candidate.Start()) { session = candidate; return true; }
            }
            catch { }
            candidate.Dispose();
            return false;
        }

        public static HdcShellSession StartIfSupported(string application, string serial, string marker)
        {
            HdcShellSession session;
            return TryStart(application, serial, marker, out session) ? session : null;
        }

        private bool Start()
        {
            master = posix_openpt(2 /*O_RDWR*/ | 0x100 /*O_NOCTTY*/);
            if (master < 0) return false;
            if (grantpt(master) != 0 || unlockpt(master) != 0) return false;
            string slave = Marshal.PtrToStringAnsi(ptsname(master));
            if (string.IsNullOrEmpty(slave)) return false;

            var info = new ProcessStartInfo("/bin/sh") {
                UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true
            };
            info.ArgumentList.Add("-c");
            info.ArgumentList.Add("exec '" + application.Replace("'", "'\\''") + "' -t '" +
                serial.Replace("'", "'\\''") + "' shell < " + slave);
            process = Process.Start(info);
            if (process == null) return false;

            Task.Run(() => DrainMaster());
            Task.Run(() => ReadLoop(process.StandardOutput, false));
            Task.Run(() => ReadLoop(process.StandardError, true));

            var startup = new ConcurrentQueue<Chunk>();
            active = startup;
            // Wait for the remote prompt before typing: input sent earlier is
            // not buffered by hdc and would be lost. Test shims and broken
            // clients exit immediately; do not sit on the full timeout.
            var promptWait = Stopwatch.StartNew();
            while (promptWait.ElapsedMilliseconds < 8000 && startup.IsEmpty)
            {
                if (process.HasExited) return false;
                Thread.Sleep(5);
            }
            if (startup.IsEmpty) return false;
            DrainQuiet(startup, 200, 3000);
            if (!Alive) return false;

            WriteMaster(StartupLine());
            DrainUntilPrompt(startup, 200, 2500);
            WriteMaster(FunctionLine());
            DrainUntilPrompt(startup, 250, 3500);
            // Probe the full function path before advertising the session.
            WriteMaster(Invocation(":", "/", "", 0, false));
            var ready = Stopwatch.StartNew();
            int seen = 0;
            while (ready.ElapsedMilliseconds < 5000 && seen < 2 && Alive)
            {
                Chunk chunk;
                while (startup.TryDequeue(out chunk))
                {
                    seen += CountOccurrences(chunk.Text, marker);
                }
                if (seen < 2) Thread.Sleep(5);
            }
            DrainQuiet(startup, 150, 1500);
            active = null;
            return Alive && !faulted && seen >= 2;
        }

        private static int CountOccurrences(string text, string value)
        {
            int count = 0, index = 0;
            while ((index = text.IndexOf(value, index, StringComparison.Ordinal)) >= 0)
            { count++; index += value.Length; }
            return count;
        }

        private string StartupLine()
        {
            return "__TS_RM='" + marker.Replace("'", "'\\''") + "'; export __TS_RM\n";
        }

        // The wrapper is parsed once at session start. Each command then only
        // invokes this function with the user text; this keeps the interactive
        // input line short, which is what dominates device-side latency.
        private static string FunctionLine()
        {
            return "__ts_run() { ( exec </dev/null; read -r __p __c __s __pp __pg __r < /proc/self/stat; " +
                "print -n \"$__TS_RM\"\"PID:$__p:$__pg\\n\"; " +
                "trap 'print -n \"$__TS_RM\"\"130\\n$PWD\\n\"; exit 130' INT; " +
                "cd \"$2\" || exit; OLDPWD=\"$3\"; " +
                "if [ \"$5\" = 1 ]; then eval \"$1\" 2>&1 | base64; __ts=${PIPESTATUS[0]:-0}; " +
                "else if [ \"$4\" = 0 ]; then :; else (exit \"$4\"); fi; eval \"$1\" 2>&1; __ts=$?; fi; " +
                "print -n \"$__TS_RM$__ts\\n$PWD\\n\" ) | ( trap '' INT; exec cat ); }\n";
        }

        private static string Invocation(string command, string cwd, string oldCwd, int lastExitCode,
            bool base64)
        {
            return "__ts_run '" + command.Replace("'", "'\\''") + "' '" +
                cwd.Replace("'", "'\\''") + "' '" + oldCwd.Replace("'", "'\\''") + "' " +
                lastExitCode + (base64 ? " 1" : " 0") + "\n";
        }

        public bool CanRun(string command, string cwd, string oldCwd, int lastExitCode, bool base64)
        {
            return Alive && Invocation(command, cwd, oldCwd, lastExitCode, base64).Length <= MaxScriptLength;
        }

        private void ReadLoop(StreamReader reader, bool error)
        {
            var buffer = new char[4096];
            try
            {
                int count;
                while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    var chunk = new Chunk { Text = new string(buffer, 0, count), Error = error };
                    var queue = active;
                    if (queue != null) queue.Enqueue(chunk);
                }
            }
            catch { }
        }

        private void DrainMaster()
        {
            var buffer = new byte[4096];
            while (true)
            {
                try
                {
                    // Echo and line-editor redraws go to the PTY master. If this
                    // buffer is not drained the remote line editor eventually
                    // blocks forever.
                    if (read(master, buffer, (IntPtr)buffer.Length).ToInt64() <= 0) break;
                }
                catch { break; }
            }
        }

        private void WriteMaster(string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            int offset = 0;
            while (offset < bytes.Length)
            {
                var part = new byte[bytes.Length - offset];
                Array.Copy(bytes, offset, part, 0, part.Length);
                long written;
                try { written = write(master, part, (IntPtr)part.Length).ToInt64(); }
                catch { throw new IOException("设备会话写入失败。"); }
                if (written <= 0) throw new IOException("设备会话写入失败。");
                offset += (int)written;
            }
        }

        private static string DrainQuiet(ConcurrentQueue<Chunk> queue, int quietMs, int maxMs)
        {
            var text = new StringBuilder();
            var watch = Stopwatch.StartNew();
            long last = 0;
            while (watch.ElapsedMilliseconds < maxMs)
            {
                bool got = false;
                Chunk chunk;
                while (queue.TryDequeue(out chunk)) { got = true; text.Append(chunk.Text); }
                if (got) last = watch.ElapsedMilliseconds;
                else if (watch.ElapsedMilliseconds - last >= quietMs) break;
                Thread.Sleep(5);
            }
            return text.ToString();
        }

        private static string DrainUntilPrompt(ConcurrentQueue<Chunk> queue, int quietMs, int maxMs)
        {
            var text = new StringBuilder();
            var watch = Stopwatch.StartNew();
            long last = 0;
            while (watch.ElapsedMilliseconds < maxMs)
            {
                bool got = false;
                Chunk chunk;
                while (queue.TryDequeue(out chunk)) { got = true; text.Append(chunk.Text); }
                if (got) last = watch.ElapsedMilliseconds;
                else if (watch.ElapsedMilliseconds - last >= quietMs) break;
                if (got)
                {
                    string trimmed = text.ToString().TrimEnd('\r', '\n', ' ');
                    if (trimmed.EndsWith("#") || trimmed.EndsWith("$")) break;
                }
                Thread.Sleep(got ? 1 : 5);
            }
            return text.ToString();
        }

        public HdcShellProcessResult Run(string command, string cwd, string oldCwd, int lastExitCode,
            string marker, bool capture, bool base64, Type editorType)
        {
            var result = new HdcShellProcessResult { Faulted = true };
            if (!Alive) return result;
            string line = Invocation(command, cwd, oldCwd, lastExitCode, base64);
            if (line.Length > MaxScriptLength) return result;

            var captured = capture ? new StringBuilder() : null;
            bool suppress = false, binaryHalt = false;
            Action<string> rawWrite = capture
                ? text => captured.Append(text)
                : text => Console.Write(text);
            Action<string> write = text =>
            {
                if (suppress || binaryHalt) return;
                if (HdcShellProcess.LooksLikeBinary(text))
                {
                    binaryHalt = true;
                    suppress = true;
                    if (!capture)
                        Console.Write("\x1b[0m\r\n[hdc shell] 检测到二进制输出，已停止显示；" +
                            "请使用 base64/xxd/od 查看，或用 hdc file recv 传输文件。\x1b[0m\r\n");
                    return;
                }
                rawWrite(text);
            };
            var stream = new HdcShellOutputStream(marker, write);
            var queue = new ConcurrentQueue<Chunk>();
            active = queue;
            using var input = new HdcShellProcess.Input(editorType);
            bool started = false, interrupted = false;
            int signalStage = 0;
            var stop = new Stopwatch();
            string preamble = "";
            var b64 = new StringBuilder();
            string markerTail = "";
            Stream rawOut = null;

            void WriteDecoded(byte[] bytes)
            {
                if (suppress) return;
                if (capture) { captured.Append(Encoding.UTF8.GetString(bytes)); return; }
                if (rawOut == null) rawOut = Console.OpenStandardOutput();
                rawOut.Write(bytes, 0, bytes.Length);
                rawOut.Flush();
            }

            void DecodeBase64(string text)
            {
                foreach (char c in text)
                {
                    if (char.IsWhiteSpace(c)) continue;
                    b64.Append(c);
                    if (b64.Length < 4) continue;
                    string group = b64.ToString(0, 4);
                    b64.Remove(0, 4);
                    try { WriteDecoded(Convert.FromBase64String(group)); } catch { }
                }
            }

            void FlushBase64()
            {
                if (b64.Length < 2) { b64.Clear(); return; }
                string group = b64.ToString();
                b64.Clear();
                group = group.PadRight((group.Length + 3) / 4 * 4, '=');
                try { WriteDecoded(Convert.FromBase64String(group)); } catch { }
            }

            bool ProcessBase64(string text)
            {
                string data = markerTail + text;
                markerTail = "";
                int at = data.IndexOf('@');
                if (at < 0) { DecodeBase64(data); return false; }
                DecodeBase64(data.Substring(0, at));
                string rest = data.Substring(at);
                if (rest.StartsWith(marker, StringComparison.Ordinal))
                {
                    FlushBase64();
                    stream.Push(rest);
                    return stream.Complete;
                }
                if (marker.StartsWith(rest, StringComparison.Ordinal))
                {
                    markerTail = rest;
                    return false;
                }
                // Base64 never contains '@'; an unexpected one is dropped.
                return ProcessBase64(rest.Substring(1));
            }

            try
            {
                WriteMaster(line);
                bool Process(Chunk chunk)
                {
                    if (chunk.Error) { write(chunk.Text); return false; }
                    if (started)
                    {
                        if (base64) return ProcessBase64(chunk.Text);
                        stream.Push(chunk.Text); return stream.Complete;
                    }
                    preamble += chunk.Text;
                    int index = preamble.IndexOf(marker, StringComparison.Ordinal);
                    if (index >= 0)
                    {
                        string after = preamble.Substring(index + marker.Length);
                        // The startup echo also contains the marker. A real
                        // command starts with the PID record. Wait for the whole
                        // line so base64 data after it is not decoded as output.
                        if (after.StartsWith("PID:"))
                        {
                            int newline = after.IndexOf('\n');
                            if (newline < 0) return false;
                            string pidLine = after.Substring(0, newline + 1);
                            started = true;
                            stream.Push(marker + pidLine);
                            preamble = "";
                            string rest = after.Substring(newline + 1);
                            if (rest.Length > 0)
                            {
                                if (base64) return ProcessBase64(rest);
                                stream.Push(rest);
                            }
                            return stream.Complete;
                        }
                        if (after.Length < "PID:".Length && "PID:".StartsWith(after)) return false;
                        // Discard the stale startup echo and keep looking.
                        preamble = after;
                        if (preamble.Length > 65536) preamble = preamble.Substring(preamble.Length - marker.Length);
                    }
                    else if (preamble.Length > 65536)
                    {
                        preamble = preamble.Substring(preamble.Length - Math.Min(marker.Length - 1, preamble.Length));
                    }
                    return false;
                }
                while (true)
                {
                    if (input.Poll())
                    {
                        interrupted = true;
                        // Ctrl+C stops the display; keep decoding markers so the
                        // prompt can return without waiting for the backlog.
                        suppress = true;
                        if (!stop.IsRunning) stop.Start();
                    }
                    bool had = false;
                    for (int batch = 0; batch < 256 && queue.TryDequeue(out Chunk chunk); batch++)
                    {
                        had = true;
                        if (Process(chunk)) break;
                    }
                    if (stream.Complete) break;
                    if (binaryHalt && !interrupted) { interrupted = true; if (!stop.IsRunning) stop.Start(); }
                    if (interrupted && !process.HasExited)
                    {
                        if (signalStage == 0 && stream.Pid > 1) { HdcShellProcess.Signal(application, serial, stream, "INT"); signalStage = 1; }
                        if (signalStage < 2 && stop.ElapsedMilliseconds > 2000 && stream.Pid > 1)
                        { HdcShellProcess.Signal(application, serial, stream, "TERM"); signalStage = 2; }
                        if (stop.ElapsedMilliseconds > 3500)
                        {
                            HdcShellProcess.Signal(application, serial, stream, "KILL");
                            // Without the trap's final marker the channel can
                            // no longer be trusted; rebuild it next time.
                            faulted = true;
                            break;
                        }
                    }
                    if (!Alive) break;
                    if (!had) Thread.Sleep(2);
                }
                stream.Finish();
                result = new HdcShellProcessResult {
                    ExitCode = interrupted ? 130 : stream.ExitCode ?? 1,
                    Directory = stream.Directory, Interrupted = interrupted && !binaryHalt,
                    BinaryHalt = binaryHalt,
                    Output = captured?.ToString(), Faulted = faulted || (!stream.Complete && !interrupted && !binaryHalt)
                };
                return result;
            }
            catch
            {
                faulted = true;
                return result;
            }
            finally
            {
                active = null;
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            active = null;
            try { if (process != null && !process.HasExited) process.Kill(true); } catch { }
            try { if (master >= 0) close(master); } catch { }
            try { process?.WaitForExit(500); } catch { }
            master = -1;
        }
    }
}
