"""Real-device regression for overflowing menus and terminal resize.

python3 tests/HdcShell.Menu.Integration.py SERIAL
Requires pwsh, hdc, pexpect, pyte. Executes only seq/pwd on the device;
selected completions are cancelled, never executed. History is temporary.
"""
import base64
import json
import os
import pathlib
import sys
import tempfile
import time

import pexpect
import pyte

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT_CS = r'''
using System; using System.IO; using System.Reflection; using System.Text; using System.Threading;
public static class MenuSnapshot {
    static Timer timer; static string previous;
    public static void Start(Type type, string path) {
        var method = type.GetMethod("GetBufferState", new Type[] { typeof(string).MakeByRefType(), typeof(int).MakeByRefType() });
        timer = new Timer(_ => { try {
            object[] args = { null, 0 }; method.Invoke(null, args);
            if (args[0] is not string line) return;
            string record = Convert.ToBase64String(Encoding.UTF8.GetBytes(line)) + ":" + args[1] + "\n";
            if (record != previous) { File.AppendAllText(path, record); previous = record; }
        } catch {} }, null, 0, 5);
    }
}
'''
checks = 0
with tempfile.TemporaryDirectory(prefix='hdc-menu-test-') as temp:
    folder = pathlib.Path(temp)
    snapshot = folder / 'snapshot'
    expected_path = folder / 'expected.json'
    (folder / 'Snapshot.cs').write_text(SNAPSHOT_CS)
    module = os.environ.get('HDC_TEST_MODULE', str(ROOT / 'TerminalSuggestions/TerminalSuggestions.psd1')).replace("'", "''")
    startup = (
        f"Import-Module '{module}'; Set-PSReadLineOption -HistorySavePath '{folder}/history'; "
        "Set-PSReadLineOption -EditMode Windows; "
        "Set-PSReadLineKeyHandler -Chord Ctrl+f -BriefDescription OriginalMenuTest -ScriptBlock {}; "
        f"Add-Type -Path '{folder}/Snapshot.cs'; [MenuSnapshot]::Start([Microsoft.PowerShell.PSConsoleReadLine],'{snapshot}'); "
        "& (Get-Module TerminalSuggestions) { $script:MenuTestEditor=(Get-Command Enable-HdcShellEditor).ScriptBlock; "
        "function script:Enable-HdcShellEditor { & $script:MenuTestEditor; "
        f"[IO.File]::WriteAllText('{expected_path}', ((Get-HdcShellCompletion '' 0).CompletionMatches.ListItemText | ConvertTo-Json)) "
        "} }"
    )
    child = pexpect.spawn('pwsh', ['-NoLogo', '-NoProfile', '-NoExit', '-Command', startup],
                          encoding='utf8', dimensions=(18, 100))

    class Terminal(pyte.Screen):
        def write_process_input(self, data):
            child.send(data)

    screen = Terminal(100, 18)
    stream = pyte.Stream(screen)
    transcript = ''

    def check(condition, message):
        global checks
        if not condition:
            raise AssertionError(message + '\n' + '\n'.join(screen.display))
        checks += 1

    def pump(seconds=.35):
        global transcript
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                text = child.read_nonblocking(65536, timeout=.05)
                transcript += text
                stream.feed(text)
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                break
        if 'exception occurred in custom key handler' in transcript.lower():
            check(False, 'Menu handler raised an exception')

    def send(text, seconds=.35):
        child.send(text)
        pump(seconds)

    def wait(text):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            pump(.1)
            if text in transcript:
                return
        check(False, 'Timed out waiting for ' + text)

    def buffer():
        for record in reversed(snapshot.read_bytes().splitlines()):
            try:
                value, cursor = record.rsplit(b':', 1)
                return base64.b64decode(value).decode(), int(cursor)
            except (ValueError, UnicodeError):
                pass
        raise AssertionError('No input snapshot')

    def wait_buffer(value, cursor):
        expected_buffer = (value, cursor)
        end = time.monotonic() + 15
        while time.monotonic() < end and buffer() != expected_buffer:
            pump(.1)
        check(buffer() == expected_buffer, 'Selection or cursor changed: ' + repr(buffer()))

    def selected(name):
        wait_buffer(name + ' ', len(name) + 1)

    def resize(rows, columns):
        child.setwinsize(rows, columns)
        screen.resize(lines=rows, columns=columns)
        pump(.2)

    try:
        wait('PS ')
        pump(.4)
        send("$global:MenuTestInitialErrorCount=$Error.Count; Enter-HdcShell -Serial '" + sys.argv[1].replace("'", "''") + "'\r", .7)
        wait(sys.argv[1] + ' /')
        pump(.4)
        expected = json.loads(expected_path.read_text())
        check(len(expected) > 100, 'Need a large device command set to reproduce the overflow')
        send('seq 1 50\r', .6)  # Fill the terminal and put the prompt near the bottom.
        send('\t', .7)
        check(buffer() == ('', 0), 'Listing candidates changed the command')
        send('\t')
        selected(expected[0])
        send('\x1b[Z')
        selected(expected[-1])  # Reverse selection reaches beyond the visible viewport.
        send('\x1b[B')
        selected(expected[0])
        resize(6, 45)
        send('\t')
        index = 1
        selected(expected[index])
        for _ in range(16):
            send('\t', .15)
            index += 1
        selected(expected[index])
        resize(4, 55)
        send('\x1b[Z')
        index -= 1
        selected(expected[index])
        resize(24, 160)
        send('\t')
        index += 1
        selected(expected[index])
        send('\x07')
        wait_buffer('', 0)
        send('pwd\r', .5)
        check(any(line.strip() == '/' for line in screen.display), 'Device shell did not recover after menu cancellation')
        send('\x04')
        wait('已退出 hdc shell。')
        send("Write-Host ('MENU_RESTORE=' + (Get-PSReadLineOption).EditMode + ',' + (Get-PSReadLineKeyHandler -Chord Ctrl+f).Function)\r", .5)
        wait('MENU_RESTORE=Windows,OriginalMenuTest')
        check('MENU_RESTORE=Windows,OriginalMenuTest' in transcript, 'Host keys or editing mode were not restored')
        send("Write-Host ('MENU_NEW_ERRORS=' + ($Error.Count - $global:MenuTestInitialErrorCount))\r", .4)
        wait('MENU_NEW_ERRORS=0')
        check('MENU_NEW_ERRORS=0' in transcript, 'Console operations generated hidden PowerShell errors')
        send('exit\r')
        print(f'PASS: {checks} long-menu, resize, cancellation and restoration checks ({len(expected)} candidates)')
    finally:
        child.close(force=True)
