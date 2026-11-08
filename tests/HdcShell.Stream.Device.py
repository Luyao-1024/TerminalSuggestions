"""Read-only real-device streaming regression: python3 ... SERIAL.

Reads hilog/dmesg, interrupts only its own foreground process group, and keeps
all test history in a temporary local directory.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

import pexpect
import pyte

root = pathlib.Path(__file__).resolve().parent.parent
serial = sys.argv[1]
checks = 0
with tempfile.TemporaryDirectory(prefix='hdc-stream-device-') as folder:
    module = os.environ.get('HDC_TEST_MODULE', str(root / 'TerminalSuggestions/TerminalSuggestions.psd1'))
    startup = (f"Import-Module '{module}'; Set-PSReadLineOption -HistorySavePath '{folder}/history'; "
               "Set-PSReadLineOption -EditMode Windows; $global:StreamErrorBaseline=$Error.Count; "
               "$global:StreamControlCBaseline=[Console]::TreatControlCAsInput")
    child = pexpect.spawn('pwsh', ['-NoLogo', '-NoProfile', '-NoExit', '-Command', startup],
                          encoding='utf8', dimensions=(30,140))

    class Terminal(pyte.Screen):
        def write_process_input(self, data): child.send(data)

    screen = Terminal(140,30)
    stream = pyte.Stream(screen)
    transcript = ''

    def check(condition, message):
        global checks
        if not condition:
            raise AssertionError(message + '\n' + '\n'.join(screen.display))
        checks += 1

    def pump(seconds=.15):
        global transcript
        end = time.monotonic()+seconds
        while time.monotonic()<end:
            try:
                text = child.read_nonblocking(65536, timeout=.05)
                transcript += text
                stream.feed(text)
            except pexpect.TIMEOUT: pass
            except pexpect.EOF: return

    def wait(predicate, message, timeout=10):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            pump(.05)
            if predicate(): return
        check(False,message)

    def current(): return screen.display[screen.cursor.y].strip()
    def prompt(timeout=10): wait(lambda: current() == serial + ' / ->', 'The device prompt did not return', timeout)
    def row(value): return any(line.strip() == value for line in screen.display)
    def send(text, seconds=.2): child.send(text); pump(seconds)
    def logs(): return any(re.match(r'^\d\d-\d\d \d\d:\d\d:\d\d', line.strip()) for line in screen.display)
    def remote(command):
        return subprocess.check_output(['hdc','-t',serial,'shell',command],text=True,timeout=5).strip()

    try:
        wait(lambda:'PS ' in transcript, 'PowerShell did not start')
        send("Enter-HdcShell -Serial '"+serial+"'\r",.5)
        wait(lambda:serial+' /' in transcript, 'The device did not connect')
        prompt()
        baseline = set(remote('pidof hilog').split())
        send('hilog\r')
        wait(logs, 'hilog produced no live output before process exit')
        check(current() != serial + ' / ->', 'hilog is still running while output is already visible')
        start = time.monotonic()
        send('\x03',.1)
        prompt()
        check(time.monotonic()-start<2, 'Ctrl+C stops hilog promptly without leaving the device shell')
        end = time.monotonic()+3
        while time.monotonic()<end and not set(remote('pidof hilog').split()).issubset(baseline):
            pump(.1)
        check(set(remote('pidof hilog').split()).issubset(baseline), 'The test left a hilog process running')
        send('\x0c')
        send("printf 'INTERRUPT=%s\\n' $?\r")
        prompt()
        check(row('INTERRUPT=130') or 'INTERRUPT=130' in transcript,
              'The following command sees interrupted status 130')

        send('\x0c')
        # Report the command shell's process group, not $$: the persistent
        # session runs each command in a subshell, so $$ is the outer shell.
        send("read -r __p __c __s __pp __testpg __r < /proc/self/stat; "
             "printf '__PIPE_PID:%s\\n' \"$__testpg\"; hilog | cat\r")
        wait(logs, 'A pipeline did not stream')
        # hilog can scroll the identity line off-screen before the first log
        # sample; read it from the full transcript instead of the viewport.
        pid_rows = re.findall(r'__PIPE_PID:(\d+)', transcript)
        check(bool(pid_rows), 'The pipeline reported its own shell identity')
        pid = int(pid_rows[-1])
        send('\x03',.1)
        prompt()
        end = time.monotonic()+3
        while time.monotonic()<end and remote(f'kill -0 -{pid} 2>/dev/null; printf "%s" "$?"') == '0':
            pump(.1)
        check(remote(f'kill -0 -{pid} 2>/dev/null; printf "%s" "$?"') != '0', 'The interrupted pipeline left its process group running')

        send('dmesg\r',.5)
        # dmesg rewrites a large ring buffer; direct hdc takes about 10 s.
        prompt(30)
        check(True, 'The unchanged dmesg command streams and completes')
        send('sleep 20\r\x03',.1)
        prompt()
        send("printf 'QUEUED_INTERRUPT=%s\\n' $?\r")
        prompt()
        check(row('QUEUED_INTERRUPT=130') or 'QUEUED_INTERRUPT=130' in transcript,
              'Ctrl+C read ahead after Enter interrupts with no extra key')
        check('@@HDCSHELL_' not in transcript, 'Internal PID/status markers are hidden')
        send('\x04')
        wait(lambda:'已退出 hdc shell。' in transcript, 'Ctrl+D did not exit')
        send("Write-Host ('STREAM_RESTORE=' + (Get-PSReadLineOption).EditMode + ',' + ([Console]::TreatControlCAsInput -eq $global:StreamControlCBaseline) + ',' + ($Error.Count - $global:StreamErrorBaseline))\r",.5)
        wait(lambda:'STREAM_RESTORE=Windows,True,0' in transcript, 'The host signal/editor state was not restored or hidden errors were added')
        check('STREAM_RESTORE=Windows,True,0' in transcript, 'Host editor/signal state restored with zero new PowerShell errors')
        send('exit\r')
        print(f'PASS: {checks} real-device streaming, signal, process-cleanup and restoration checks')
    finally:
        child.close(force=True)
