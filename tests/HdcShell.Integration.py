"""Read-only device/keyboard regression: python3 tests/HdcShell.Integration.py SERIAL.

Test dependencies: pexpect, pyte, pwsh and hdc in PATH. All test history lives in
an automatically removed local temp directory. No device files are written.
"""
import pathlib
import os
import sys
import tempfile
import time
import subprocess
import json

import pexpect
import pyte

root = pathlib.Path(__file__).resolve().parent.parent
serial = sys.argv[1]
prompt_text = serial + ' / ->'
checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message + '\n' + '\n'.join(screen.display))
    checks += 1


with tempfile.TemporaryDirectory(prefix='hdc-shell-test-') as temp:
    history = pathlib.Path(temp) / 'host.txt'
    history.write_text('echo HOST_HISTORY_MUST_STAY_OUT\n')
    module_path = os.environ.get('HDC_TEST_MODULE', str(root / 'TerminalSuggestions/TerminalSuggestions.psd1')).replace("'", "''")
    startup = (f"Import-Module '{module_path}'; "
               f"Set-PSReadLineOption -HistorySavePath '{history}'; "
               "Set-PSReadLineOption -EditMode Windows; "
               "Set-PSReadLineKeyHandler -Chord Ctrl+f -BriefDescription HostCustom -ScriptBlock { }")
    startup_calls = pathlib.Path(temp) / 'startup-queries.jsonl'
    startup += ("; & (Get-Module TerminalSuggestions) { "
                "$script:StartupCapture=(Get-Command Invoke-HdcCapture).ScriptBlock; "
                "function script:Invoke-HdcCapture { param($Application, $Arguments, $TimeoutSeconds=15); "
                f"[IO.File]::AppendAllText('{startup_calls}', (ConvertTo-Json -InputObject $Arguments[-1] -Compress) + \"`n\"); "
                "& $script:StartupCapture $Application $Arguments -TimeoutSeconds $TimeoutSeconds } }")
    child = pexpect.spawn('pwsh', ['-NoLogo', '-NoProfile', '-NoExit', '-Command', startup],
                          encoding='utf-8', timeout=15, dimensions=(40,140))

    class Terminal(pyte.Screen):
        def write_process_input(self, data):
            # Answer .NET console cursor position queries like a real terminal.
            child.send(data)

    screen = Terminal(140, 40)
    stream = pyte.Stream(screen)

    def pump(seconds=.4):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                stream.feed(child.read_nonblocking(65536, timeout=min(.1, max(.001, end-time.monotonic()))))
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                return

    def wait(text, seconds=15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            pump(.1)
            if any(text in line for line in screen.display):
                return
            if not child.isalive():
                break
        check(False, 'Timed out waiting for ' + text)

    def send(text):
        child.send(text)
        pump(.6)

    def command(text):
        send(text + '\r')

    def current():
        return screen.display[screen.cursor.y].rstrip()

    try:
        wait('PS ')
        pump(.7)
        command("Enter-HdcShell -Serial '" + serial.replace("'", "''") + "'")
        wait(prompt_text)
        check(not any('当前版本' in line or '已连接' in line for line in screen.display), 'No version or connection banner delays the first prompt')
        queries = [json.loads(line) for line in startup_calls.read_text().splitlines()]
        check(queries == ['pwd'], 'Entry only queries cwd; version, HOME and command scanning do not delay the first prompt')
        pump(.8)
        check(current() == prompt_text, 'Initial device prompt')
        check(all(screen.buffer[screen.cursor.y][i].fg == 'green' for i in range(len(prompt_text)-2, len(prompt_text))), 'Initial success arrow is green')
        send('echo "unterminated')
        check(all(screen.buffer[screen.cursor.y][i].fg == 'green' for i in range(len(prompt_text)-2, len(prompt_text))), 'Incomplete input does not overwrite the last command status color')
        send('\x03')
        check(all(screen.buffer[screen.cursor.y][i].fg == 'red' for i in range(len(prompt_text)-2, len(prompt_text))), 'Cancelling an input line makes the arrow red')
        send('cd /data/loc\t')
        wait(prompt_text + ' cd /data/local/')
        check(current().endswith(prompt_text + ' cd /data/local/'), 'Remote directory completion')
        path_start = len(prompt_text + ' cd ')
        check(all(screen.buffer[screen.cursor.y][i].underscore for i in range(path_start, path_start + len('/data/local/'))), 'Existing completed device directory is emphasized before Enter')
        check(all(screen.buffer[screen.cursor.y][i].fg == 'brightcyan' for i in range(path_start, path_start + len('/data/local/'))), 'Existing completed device directory has visible cyan emphasis')
        send('\x03')
        send('cd /home/luyao')
        check(not any(screen.buffer[screen.cursor.y][i].underscore for i in range(path_start, path_start + len('/home/luyao'))), 'A host-only path is not emphasized on the device')
        check(not any(screen.buffer[screen.cursor.y][i].fg == 'brightcyan' for i in range(path_start, path_start + len('/home/luyao'))), 'A missing device path retains its normal foreground')
        send('\x03')
        screenshot_path = '/data/service/el2/100/hmdfs'
        if subprocess.check_output(['hdc', '-t', serial, 'shell', 'test -d ' + screenshot_path + ' && printf exists'], text=True).strip() == 'exists':
            send('cd ' + screenshot_path)
            wait(prompt_text + ' cd ' + screenshot_path)
            check(all(screen.buffer[screen.cursor.y][i].fg == 'brightcyan' and screen.buffer[screen.cursor.y][i].underscore
                      for i in range(path_start, path_start + len(screenshot_path))), 'The exact path from the user screenshot is cyan and underlined before Enter')
            send('\x03')
        command('pwd')
        check(any(line.strip() == '/' for line in screen.display), 'Cancel did not execute cd')

        send('cd /data/lo\t\t')
        check('/data/local/' in '\n'.join(screen.display), 'Tab menu has device paths')
        send('\x1b[Z')
        chosen = current()
        check('/data/lo' in chosen, 'Shift+Tab navigates the menu')
        send('\r')
        check(current() == chosen, 'Enter confirms completion without executing')
        send('\x03')

        command('echo alpha beta')
        send('echo alph')
        check('echo alpha beta' in current(), 'Directory-local gray history prediction')
        send('\x1b[1;5C')
        send('-word')
        check(current().endswith('echo alpha -word'), 'Word acceptance includes the same separator as local zsh')
        command('')
        send('echo alph')
        send('\x05')
        check(screen.cursor.x == len(prompt_text + ' echo alpha -word'), 'Ctrl+E accepts the full suggestion at line end')
        command('')
        send('echo ABC')
        send('\x01\x06')
        check(screen.cursor.x == len(prompt_text + ' ') + 1, 'Ctrl+F in the middle only moves one character')
        send('\x03')
        send('echo HOST_HISTORY')
        check('HOST_HISTORY_MUST_STAY_OUT' not in current(), 'Host history cannot become a device prediction')
        send('\x03')

        command('cd /data/local')
        check(current() == serial + ' local ->', 'The prompt shows device SN and only the last directory name')
        command('pwd # trailing comment')
        check(any(line.strip() == '/data/local' for line in screen.display), 'Trailing comments preserve command output and cwd')
        command('false')
        check(all(screen.buffer[screen.cursor.y][i].fg == 'red' for i in range(len(serial + ' local '), len(serial + ' local ->'))), 'A failed command makes the arrow red')
        command('echo status=$?')
        check(any(line.strip() == 'status=1' for line in screen.display), 'Previous remote exit status')
        check(all(screen.buffer[screen.cursor.y][i].fg == 'green' for i in range(len(serial + ' local '), len(serial + ' local ->'))), 'A successful next command restores the green arrow')
        command('cd -')
        check(current() == prompt_text, 'cd - returns to the previous directory')
        send('\x0c')
        check(prompt_text in current(), 'Ctrl+L redraws the device prompt')
        send('\x03')
        check(current() == prompt_text, 'Empty Ctrl+C stays in the device shell')
        send('\x04')
        wait('已退出 hdc shell。')
        command("Write-Host ('RESTORE=' + (Get-PSReadLineOption).EditMode + ',' + (Get-PSReadLineKeyHandler -Chord Ctrl+f).Function)")
        check('RESTORE=Windows,HostCustom' in '\n'.join(screen.display), 'Host edit mode and custom callback are restored')
        command('exit')
        pump(.2)
        host_lines = history.read_text().splitlines()
        check('echo alpha beta' not in host_lines, 'Device commands never enter host history')
        print(f'PASS: {checks} device and keyboard checks')
    finally:
        if child.isalive():
            child.close(force=True)
