using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.RegularExpressions;

namespace TerminalSuggestions
{
    // Decorate only PSReadLine's generated input lines. Its renderer still owns
    // cursor placement, wrapping, selection, prediction and all key handling.
    // DispatchProxy also forwards its private IConsole interface on Windows.
    public class HdcShellPathConsole : DispatchProxy
    {
        private const BindingFlags Fields = BindingFlags.Instance | BindingFlags.NonPublic;
        private object target, editor;
        private FieldInfo bufferField, linesField, optionsField;
        private Func<string, int[]> provider;
        private string lastInput;
        private int[] spans = Array.Empty<int>();
        private static readonly Regex Sgr = new Regex("\x1b\\[[0-9;:]*m", RegexOptions.Compiled);

        public static HdcShellPathConsole Install(Type editorType, Func<string, int[]> provider)
        {
            object editor = editorType.GetField("_singleton", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
            FieldInfo console = editorType.GetField("_console", Fields);
            // Validate before replacing the console, so startup failures leave
            // the original editor untouched.
            FieldInfo buffer = editorType.GetField("_buffer", Fields);
            FieldInfo lines = editorType.GetField("_consoleBufferLines", Fields);
            FieldInfo options = editorType.GetField("_options", Fields);
            if (buffer == null || lines == null || options == null)
                throw new NotSupportedException("此 PSReadLine 版本不支持设备路径高亮。");
            var proxy = (HdcShellPathConsole)Create(console.FieldType, typeof(HdcShellPathConsole));
            proxy.target = console.GetValue(editor);
            proxy.editor = editor;
            proxy.bufferField = buffer;
            proxy.linesField = lines;
            proxy.optionsField = options;
            proxy.provider = provider;
            console.SetValue(editor, proxy);
            return proxy;
        }

        public void Reset() { lastInput = null; spans = Array.Empty<int>(); }

        protected override object Invoke(MethodInfo method, object[] arguments)
        {
            if (method.Name == "Write" && arguments.Length == 1 && arguments[0] is string text)
                arguments[0] = Decorate(text);
            try { return method.Invoke(target, arguments); }
            catch (TargetInvocationException error) when (error.InnerException != null)
            {
                ExceptionDispatchInfo.Capture(error.InnerException).Throw();
                throw;
            }
        }

        private string Decorate(string text)
        {
            if (text.Length == 0 || text.IndexOf('\x1b') < 0) return text;
            string input = bufferField.GetValue(editor).ToString();
            if (input.Length == 0) return text;
            var lines = (List<StringBuilder>)linesField.GetValue(editor);
            string[] logical = input.Split('\n');
            int offset = 0;
            for (int i = 0; i < logical.Length && i < lines.Count; i++)
            {
                if (lines[i].ToString() == text)
                {
                    if (lastInput != input)
                    {
                        spans = provider(input) ?? Array.Empty<int>();
                        lastInput = input;
                    }
                    if (spans.Length == 0) return text;
                    int prefix = 0;
                    if (i != 0)
                    {
                        object options = optionsField.GetValue(editor);
                        string prompt = (string)options.GetType().GetProperty("ContinuationPrompt").GetValue(options);
                        prefix = Sgr.Replace(prompt, "").Length;
                    }
                    return Emphasize(text, logical[i], offset, prefix, spans);
                }
                offset += logical[i].Length + 1;
            }
            return text;
        }

        // Public for focused ANSI regression checks. Offsets are UTF-16 input
        // offsets; ANSI styles consume no cells, controls render as two chars.
        public static string Emphasize(string rendered, string input, int offset, int prefix, int[] spans)
        {
            var wanted = new List<bool>();
            for (int i = 0; i < prefix; i++) wanted.Add(false);
            for (int i = 0; i < input.Length; i++)
            {
                bool path = false;
                for (int j = 0; j + 1 < spans.Length; j += 2)
                    if (offset + i >= spans[j] && offset + i < spans[j] + spans[j + 1]) { path = true; break; }
                wanted.Add(path);
                if (char.IsControl(input[i])) wanted.Add(path);
            }
            var result = new StringBuilder(rendered.Length + 32);
            int visible = 0;
            string nativeForeground = "\x1b[39m", actualForeground = nativeForeground;
            bool nativeUnderline = false, actualUnderline = false;
            for (int i = 0; i < rendered.Length;)
            {
                Match sgr = rendered[i] == '\x1b' ? Sgr.Match(rendered, i) : Match.Empty;
                if (sgr.Success && sgr.Index == i)
                {
                    result.Append(sgr.Value);
                    string codes = sgr.Value.Substring(2, sgr.Length - 3);
                    ApplySgr(codes, ref nativeForeground, ref nativeUnderline);
                    ApplySgr(codes, ref actualForeground, ref actualUnderline);
                    i += sgr.Length;
                    continue;
                }
                bool path = visible < wanted.Count && wanted[visible];
                string foreground = path ? "\x1b[38;2;0;255;255m" : nativeForeground;
                bool underline = path || nativeUnderline;
                if (foreground != actualForeground) result.Append(foreground);
                if (underline != actualUnderline) result.Append(underline ? "\x1b[4m" : "\x1b[24m");
                actualForeground = foreground;
                actualUnderline = underline;
                result.Append(rendered[i++]);
                visible++;
            }
            if (actualForeground != nativeForeground) result.Append(nativeForeground);
            if (actualUnderline != nativeUnderline) result.Append(nativeUnderline ? "\x1b[4m" : "\x1b[24m");
            return result.ToString();
        }

        private static void ApplySgr(string codes, ref string foreground, ref bool underline)
        {
            string[] values = codes.Split(';');
            for (int i = 0; i < values.Length; i++)
            {
                string value = values[i];
                if (value.StartsWith("38:")) { foreground = "\x1b[" + value + "m"; continue; }
                if (value.StartsWith("4:")) { underline = value != "4:0"; continue; }
                if (!int.TryParse(value == "" ? "0" : value, out int code)) continue;
                if (code == 0) { foreground = "\x1b[39m"; underline = false; }
                else if (code == 4 || code == 21) underline = true;
                else if (code == 24) underline = false;
                else if (code == 39 || (code >= 30 && code <= 37) || (code >= 90 && code <= 97))
                    foreground = "\x1b[" + code + "m";
                else if (code == 38 || code == 48 || code == 58)
                {
                    // RGB/palette operands are color components, not SGR
                    // commands: a zero component must not reset underline.
                    int operands = i + 1 < values.Length && values[i + 1] == "2" ? 4 :
                        i + 1 < values.Length && values[i + 1] == "5" ? 2 : 0;
                    if (operands > 0 && i + operands < values.Length)
                    {
                        if (code == 38) foreground = "\x1b[" + string.Join(";", values, i, operands + 1) + "m";
                        i += operands;
                    }
                }
            }
        }
    }
}
