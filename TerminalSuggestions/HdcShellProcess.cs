using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TerminalSuggestions
{
    public sealed class HdcShellProcessResult
    {
        public int ExitCode;
        public string Directory;
        public bool Interrupted;
        public bool Faulted;
        public bool BinaryHalt;
        public string Output;
    }

    // Incremental protocol decoding keeps a possible marker suffix, never an
    // entire output line. Even printf without a newline is displayed promptly.
    public sealed class HdcShellOutputStream
    {
        private readonly string marker;
        private readonly Action<string> write;
        private string pending = "";
        private int record; // 0: output; 1: marker payload; 2: cwd
        public int Pid { get; private set; }
        public int Group { get; private set; }
        public int? ExitCode { get; private set; }
        public string Directory { get; private set; }
        // True once the final cwd record arrives. A persistent session uses
        // this as the end-of-command boundary.
        public bool Complete { get; private set; }

        public HdcShellOutputStream(string marker, Action<string> write)
        {
            this.marker = marker;
            this.write = write;
        }

        public void Push(string text)
        {
            pending += text;
            while (pending.Length > 0)
            {
                if (record != 0)
                {
                    int end = pending.IndexOf('\n');
                    if (end < 0)
                    {
                        // Malformed output cannot make the decoder accumulate
                        // an unlimited record. Control records are tiny.
                        if (pending.Length > 8192) { write(marker + pending); pending = ""; record = 0; }
                        return;
                    }
                    string value = pending.Substring(0, end).TrimEnd('\r');
                    pending = pending.Substring(end + 1);
                    if (record == 2)
                    {
                        if (value.StartsWith("/"))
                        {
                            Directory = value;
                            Complete = true;
                            // The cwd record is the last protocol item. In the
                            // persistent session the outer shell's prompt
                            // follows it; never display that prompt.
                            pending = "";
                            return;
                        }
                        record = 0;
                    }
                    else if (value.StartsWith("PID:"))
                    {
                        string[] parts = value.Substring(4).Split(':');
                        if (parts.Length == 2 && int.TryParse(parts[0], out int pid) && int.TryParse(parts[1], out int group))
                        { Pid = pid; Group = group; }
                        else write(marker + value + "\n");
                        record = 0;
                    }
                    else if (int.TryParse(value, out int code) && code >= 0 && code <= 255)
                    { ExitCode = code; record = 2; }
                    else { write(marker + value + "\n"); record = 0; }
                    continue;
                }
                int position = pending.IndexOf(marker, StringComparison.Ordinal);
                if (position >= 0)
                {
                    if (position > 0) write(pending.Substring(0, position));
                    pending = pending.Substring(position + marker.Length);
                    record = 1;
                    continue;
                }
                int keep = Math.Min(pending.Length, marker.Length - 1);
                while (keep > 0 && !pending.EndsWith(marker.Substring(0, keep), StringComparison.Ordinal)) keep--;
                if (pending.Length > keep) write(pending.Substring(0, pending.Length - keep));
                pending = pending.Substring(pending.Length - keep);
                return;
            }
        }

        public void Finish()
        {
            if (record == 0) write(pending);
            else if (record == 1) write(marker + pending);
            pending = "";
        }
    }

    public static class HdcShellProcess
    {
        private sealed class Chunk { public string Text; public bool Error; }

        private static Process CreateProcess(string application, string[] arguments)
        {
            var process = new Process();
            process.StartInfo = new ProcessStartInfo(application) {
                UseShellExecute = false, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            foreach (string argument in arguments) process.StartInfo.ArgumentList.Add(argument);
            return process;
        }

        private static async Task Read(StreamReader reader, bool error, BlockingCollection<Chunk> chunks, CancellationToken token)
        {
            var buffer = new char[4096];
            try
            {
                int count;
                while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
                    chunks.Add(new Chunk { Text = new string(buffer, 0, count), Error = error }, token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        }

        public static bool LooksLikeBinary(string text)
        {
            int suspicious = 0;
            foreach (char c in text)
            {
                if (c == '\0') return true;
                if (c == '�' || c == '\x7f')
                {
                    if (++suspicious >= 2) return true;
                }
                else if (c < 0x20 && c != '\t' && c != '\n' && c != '\r' && c != '\x1b')
                {
                    if (++suspicious >= 2) return true;
                }
            }
            return false;
        }

        internal static void Signal(string application, string serial, HdcShellOutputStream stream, string signal)
        {
            // Signal only the verified group of this RPC, never a command name
            // or all hilog processes. Older daemons without a private group
            // receive a signal to this shell PID only.
            if (stream.Pid <= 1) return;
            string target = stream.Pid == stream.Group ? "-" + stream.Group : stream.Pid.ToString();
            var control = CreateProcess(application, new[] { "-t", serial, "shell", "kill -" + signal + " " + target + " 2>/dev/null" });
            try
            {
                control.Start();
                control.StandardInput.Close();
            }
            catch { control.Dispose(); return; }
            // Do not block the reader loop on the control hdc client: on a
            // loaded device its exit can take longer than the interrupt
            // itself. The delivery is asynchronous; output is not needed.
            Task.Run(() => {
                try
                {
                    var output = control.StandardOutput.ReadToEndAsync();
                    var errors = control.StandardError.ReadToEndAsync();
                    if (!control.WaitForExit(1500)) control.Kill(true);
                    control.WaitForExit();
                    Task.WaitAll(output, errors);
                }
                catch { }
                finally { control.Dispose(); }
            });
        }

        // PSReadLine can have read ahead past Enter, including Ctrl+C. Preserve
        // every other key for its next input line instead of losing typeahead.
        internal sealed class Input : IDisposable
        {
            private readonly object queue;
            private readonly MethodInfo clear, enqueue, asKey, fromKey;
            private readonly List<object> saved = new List<object>();
            private bool cancel;
            private readonly bool enabled, oldControlC;

            public Input(Type editorType)
            {
                enabled = !Console.IsInputRedirected;
                if (!enabled) return;
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
                object editor = editorType.GetField("_singleton", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
                queue = editorType.GetField("_queuedKeys", flags).GetValue(editor);
                Type queueType = queue.GetType(), keyType = queueType.GetGenericArguments()[0];
                clear = queueType.GetMethod("Clear");
                enqueue = queueType.GetMethod("Enqueue");
                asKey = keyType.GetMethod("AsConsoleKeyInfo", flags);
                fromKey = keyType.GetMethod("FromConsoleKeyInfo", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);
                if (asKey == null || fromKey == null) throw new NotSupportedException("此 PSReadLine 版本不支持命令中断输入。");
                oldControlC = Console.TreatControlCAsInput;
                Console.TreatControlCAsInput = true;
                foreach (object key in (IEnumerable)queue)
                {
                    if (IsCancel((ConsoleKeyInfo)asKey.Invoke(key, null))) cancel = true;
                    else saved.Add(key);
                }
                clear.Invoke(queue, null);
            }

            private static bool IsCancel(ConsoleKeyInfo key) => key.KeyChar == '\x03' ||
                (key.Key == ConsoleKey.C && (key.Modifiers & ConsoleModifiers.Control) != 0);

            public bool Poll()
            {
                if (!enabled) return false;
                while (Console.KeyAvailable)
                {
                    ConsoleKeyInfo key = Console.ReadKey(true);
                    if (IsCancel(key)) cancel = true;
                    else saved.Add(fromKey.Invoke(null, new object[] { key }));
                }
                bool result = cancel;
                cancel = false;
                return result;
            }

            public void Dispose()
            {
                if (!enabled) return;
                try { foreach (object key in saved) enqueue.Invoke(queue, new[] { key }); }
                finally { Console.TreatControlCAsInput = oldControlC; }
            }
        }

        public static HdcShellProcessResult Run(string application, string serial, string command, string marker, bool capture, Type editorType)
        {
            var captured = capture ? new StringBuilder() : null;
            bool suppress = false, binaryHalt = false;
            Action<string> rawWrite = capture
                ? text => captured.Append(text)
                : text => Console.Write(text);
            Action<string> write = text =>
            {
                if (suppress || binaryHalt) return;
                if (LooksLikeBinary(text))
                {
                    binaryHalt = true;
                    suppress = true;
                    if (!capture)
                        Console.Write("\x1b[0m\r\n[hdc shell] 检测到二进制输出，已停止显示；" +
                            "请使用 base64/xxd/od 查看，或使用 hdc shell --raw。\x1b[0m\r\n");
                    return;
                }
                rawWrite(text);
            };
            var stream = new HdcShellOutputStream(marker, write);
            using var input = new Input(editorType);
            using var process = CreateProcess(application, new[] { "-t", serial, "shell", command });
            using var chunks = new BlockingCollection<Chunk>(64);
            using var cancelReads = new CancellationTokenSource();
            bool started = false, interrupted = false;
            int signalStage = 0;
            var stop = new Stopwatch();
            try
            {
                process.Start();
                started = true;
                process.StandardInput.Close();
                Task stdout = Task.Run(() => Read(process.StandardOutput, false, chunks, cancelReads.Token));
                Task stderr = Task.Run(() => Read(process.StandardError, true, chunks, cancelReads.Token));
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
                    // Small poll interval keeps the post-output tail short:
                    // the loop still notices process exit promptly, and an
                    // idle wait never adds a visible 15 ms to every command.
                    if (chunks.TryTake(out Chunk chunk, 2))
                    {
                        int batch = 0;
                        do
                        {
                            if (chunk.Error) write(chunk.Text); else stream.Push(chunk.Text);
                        } while (++batch < 16 && chunks.TryTake(out chunk));
                    }
                    // A binary stream cannot cross the hdc channel reliably
                    // (NUL/control bytes truncate it), so stop the command and
                    // return to the prompt instead of waiting forever.
                    if (binaryHalt && !interrupted) { interrupted = true; if (!stop.IsRunning) stop.Start(); }
                    if (interrupted && !process.HasExited)
                    {
                        if (signalStage == 0 && stream.Pid > 1) { Signal(application, serial, stream, "INT"); signalStage = 1; }
                        if (signalStage < 2 && stop.ElapsedMilliseconds > 2000 && stream.Pid > 1)
                        { Signal(application, serial, stream, "TERM"); signalStage = 2; }
                        if (stop.ElapsedMilliseconds > 3500)
                        {
                            Signal(application, serial, stream, "KILL");
                            if (!process.HasExited) process.Kill(true);
                        }
                    }
                    if (process.HasExited && stdout.IsCompleted && stderr.IsCompleted && chunks.Count == 0)
                    { Task.WaitAll(stdout, stderr); break; }
                }
                stream.Finish();
                return new HdcShellProcessResult {
                    ExitCode = interrupted ? 130 : stream.ExitCode ?? process.ExitCode,
                    Directory = stream.Directory, Interrupted = interrupted && !binaryHalt,
                    BinaryHalt = binaryHalt, Output = captured?.ToString()
                };
            }
            finally
            {
                cancelReads.Cancel();
                if (started && !process.HasExited)
                {
                    Signal(application, serial, stream, "TERM");
                    process.Kill(true);
                    process.WaitForExit();
                }
            }
        }
    }
}
