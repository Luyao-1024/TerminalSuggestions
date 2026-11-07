"""Command-class matrix on a real device: behavior, colors and latency.

python3 tests/HdcShell.Commands.Integration.py SERIAL

Covers trivial, file-reading, stdin-reading, listing, text-search, OpenHarmony,
compound, stateful, Unicode/ANSI, streaming, large-output and unknown-command
classes. Checks executed output/status, input path emphasis, `ls` type and
extension colors, and per-class latency.

The test creates one fixture directory under /data/local/tmp and removes it in
the cleanup path; it writes no other device files. History stays in a local
temporary directory.
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
module = os.environ.get('HDC_TEST_MODULE', str(root / 'TerminalSuggestions/TerminalSuggestions.psd1'))
fixture = '/data/local/tmp/hdc_cmd_matrix_%d_%d' % (os.getpid(), int(time.time()))
checks = 0
timings = {}


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message + '\n' + '\n'.join(screen.display))
    checks += 1


def remote(command, timeout=15):
    result = subprocess.run(['hdc', '-t', serial, 'shell', command],
                            capture_output=True, text=True, timeout=timeout)
    return result.stdout + result.stderr


remote('\n'.join([
    'mkdir -p %s/sub' % fixture,
    "printf 'hello world\\n' > %s/plain.txt" % fixture,
    "printf '#!/bin/sh\\n' > %s/exec.sh" % fixture,
    'chmod 755 %s/exec.sh' % fixture,
    ': > %s/archive.zip' % fixture,
    ': > %s/image.png' % fixture,
    ': > %s/video.mp4' % fixture,
    'ln -s sub %s/link' % fixture,
    'mkfifo %s/pipe 2>/dev/null || true' % fixture,
]))

with tempfile.TemporaryDirectory(prefix='hdc-commands-') as folder:
    history = pathlib.Path(folder) / 'history'
    prompt_text = serial + ' / ->'
    startup = (f"Import-Module '{module}'; Set-PSReadLineOption -HistorySavePath '{history}'; "
               "Set-PSReadLineOption -EditMode Windows")
    child = pexpect.spawn('pwsh', ['-NoLogo', '-NoProfile', '-NoExit', '-Command', startup],
                          encoding='utf8', dimensions=(40, 200))

    class Terminal(pyte.Screen):
        def write_process_input(self, data):
            child.send(data)

    screen = Terminal(200, 40)
    stream = pyte.Stream(screen)

    def pump(seconds=.15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                stream.feed(child.read_nonblocking(65536, timeout=min(.03, max(.001, end - time.monotonic()))))
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                return

    def current():
        return screen.display[screen.cursor.y].strip()

    def wait(predicate, message, timeout=10):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pump(.03)
            if predicate():
                return
        check(False, message)

    def wait_prompt(expected=None, timeout=10):
        expected = expected or prompt_text
        wait(lambda: current() == expected, 'The prompt did not return: ' + expected, timeout)

    def row_index(value):
        for index, line in enumerate(screen.display):
            if line.strip() == value:
                return index
        return -1

    def row(value):
        return row_index(value) >= 0

    def cell(row_number, column):
        return (screen.buffer[row_number][column].fg, screen.buffer[row_number][column].underscore)

    def cells(needle, row_number=None):
        """Foreground/underline attributes of a substring in a screen row."""
        if row_number is None:
            row_number = next((i for i, line in enumerate(screen.display) if needle in line), -1)
        if row_number < 0:
            return []
        line = screen.display[row_number]
        start = line.find(needle)
        if start < 0:
            return []
        return [cell(row_number, start + i) for i in range(len(needle))]

    def expect_color(needle, color, underline=False, row_number=None):
        values = cells(needle, row_number)
        check(bool(values), 'Missing text on screen: ' + needle)
        check(all(fg == color and under == underline for fg, under in values),
              'Color for %r should be %s%s, got %s' % (needle, color,
                                                       '' if not underline else ' + underline',
                                                       sorted(set(values))))

    def expect_default(needle, row_number=None):
        values = cells(needle, row_number)
        check(bool(values), 'Missing text on screen: ' + needle)
        check(all(fg == 'default' and not under for fg, under in values),
              'Text %r should keep the default style, got %s' % (needle, sorted(set(values))))

    def expect_arrow(color, expected=None):
        expected = expected or prompt_text
        prompt_row = row_index(expected)
        check(prompt_row >= 0, 'Prompt row is missing: ' + expected)
        values = [cell(prompt_row, i) for i in range(len(expected) - 2, len(expected))]
        check(all(fg == color for fg, _ in values), 'Arrow should be %s, got %s' % (color, values))

    def send(text, seconds=.1):
        child.send(text)
        pump(seconds)

    def run(command, expected=None, timeout=15):
        """Execute a command from a clean prompt and measure until the next prompt."""
        expected = expected or prompt_text
        send('\x0c', .05)
        wait(lambda: current().endswith('->'), 'The device prompt is not ready', 5)
        before = current()
        start = time.monotonic()
        child.send(command + '\r')
        echo = (before + ' ' + command).strip()
        started = False
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pump(.03)
            if not started:
                started = any(line.strip() == echo for line in screen.display)
            if started and current() == expected:
                timings.setdefault(command.split()[0], []).append(time.monotonic() - start)
                return
        check(False, 'Timed out running: ' + command)

    def run_no_newline(command, expected_text, timeout=10):
        send('\x0c', .05)
        wait_prompt()
        start = time.monotonic()
        child.send(command + '\r')
        wait(lambda: expected_text in current() and current().endswith(prompt_text),
             'No-newline output did not return to the prompt', timeout)
        timings.setdefault(command.split()[0], []).append(time.monotonic() - start)
        check(expected_text in current(), 'No-newline output is displayed')
        send('\x0c', .1)
        wait_prompt()

    def type_line(text):
        send('\x0c', .05)
        wait_prompt()
        child.send(text)
        wait(lambda: screen.display[screen.cursor.y].rstrip().endswith(text),
             'Input is not rendered: ' + text)
        pump(.15)
        return screen.cursor.y

    def cancel_input():
        send('\x03', .1)
        wait_prompt()

    def long_row_index(name):
        for index, line in enumerate(screen.display):
            if not re.match(r'^[-dlbcps][rwxsStT-]{9}\s', line):
                continue
            # A symlink target is not the entry name; do not match "sub" in
            # "link -> sub" when looking for the directory entry.
            entry = line.split(' -> ', 1)[0].rstrip() if ' -> ' in line else line.rstrip()
            if entry.rsplit(None, 1)[-1] == name:
                return index
        return -1

    try:
        wait(lambda: 'PS ' in ''.join(screen.display), 'PowerShell did not start', 20)
        send("Enter-HdcShell -Serial '" + serial.replace("'", "''") + "'\r", .5)
        wait(lambda: prompt_text in ''.join(screen.display), 'The device prompt did not appear', 20)
        wait_prompt()

        # ---- Input emphasis: each command class keeps its own argument styles.
        for text, needle, color, underline in [
                (f'cat {fixture}/plain.txt', f'{fixture}/plain.txt', 'brightcyan', True),
                (f'cat {fixture}/missing.txt', f'{fixture}/missing.txt', 'default', False),
                (f'cd {fixture}/sub', f'{fixture}/sub', 'brightcyan', True),
                (f'ls {fixture}', fixture, 'brightcyan', True),
                (f'find {fixture} -name plain.txt', fixture, 'brightcyan', True)]:
            type_line(text)
            expect_color(needle, color, underline)
            check(cells(text.split()[0])[0][0] == 'green', 'Command name is green: ' + text)
            cancel_input()
        type_line(f'grep hello {fixture}/plain.txt')
        expect_color(f'{fixture}/plain.txt', 'brightcyan', True)
        expect_default('hello')
        cancel_input()
        type_line(f'cat "{fixture}/plain.txt"')
        expect_color(f'"{fixture}/plain.txt"', 'brown', False, screen.cursor.y)
        cancel_input()
        type_line('echo "quoted text"')
        expect_color('"quoted text"', 'brown', False)
        cancel_input()
        type_line('echo $HOME')
        expect_color('$HOME', 'cyan', False)
        cancel_input()
        type_line('ls -l')
        expect_default('-l')
        cancel_input()

        # ---- Trivial and file-reading classes.
        run('echo hello')
        check(row('hello'), 'echo output')
        expect_arrow('green')
        run('pwd')
        check(row('/'), 'pwd output')
        run(f'cat {fixture}/plain.txt')
        check(row('hello world'), 'cat file output')
        run(f'head -1 {fixture}/plain.txt')
        check(row('hello world'), 'head file output')
        run(f'tail -1 {fixture}/plain.txt')
        check(row('hello world'), 'tail file output')
        run(f'grep -n hello {fixture}/plain.txt')
        check(row('1:hello world'), 'grep file output')
        run(f'sed -n 1p {fixture}/plain.txt')
        check(row('hello world'), 'sed file output')
        run(f'sed -n 2p {fixture}/plain.txt')
        check(not row('hello world'), 'sed selects only the requested line')
        run(f'wc -l {fixture}/plain.txt')
        check(any(re.match(r"^\s*1\s+" + re.escape(fixture) + r"/plain\.txt\s*$", line)
                  for line in screen.display), 'wc file output')
        run(f'sort {fixture}/plain.txt')
        check(row('hello world'), 'sort file output')
        run_no_newline("printf 'NOEOL_OK'", 'NOEOL_OK')

        # ---- stdin-reading class: EOF instead of a blocked RPC.
        for command in ('cat', 'sort', 'head', 'grep x', 'tee'):
            start = time.monotonic()
            run(command, timeout=8)
            check(time.monotonic() - start < 3, command + ' must observe EOF without hanging')
        run('read line')
        expect_arrow('red')
        run("printf 'READ_RC=%s\\n' $?")
        check(row('READ_RC=1'), 'read reports EOF status 1')
        run('wc')
        check(any(re.match(r'^0\s+0\s+0$', line.strip()) for line in screen.display),
              'wc over empty stdin reports zero counts')
        run('base64')

        # ---- Listing class: behavior, local reflow and `ls` type/extension colors.
        run(f'ls -1 {fixture}')
        for name in ('archive.zip', 'exec.sh', 'image.png', 'link', 'pipe', 'plain.txt', 'sub', 'video.mp4'):
            check(row(name), 'ls -1 entry: ' + name)
        expect_color('archive.zip', 'brightred')
        expect_color('exec.sh', 'brightgreen')
        expect_color('image.png', 'brightmagenta')
        expect_color('link', 'brightcyan')
        expect_color('pipe', 'brightbrown')
        expect_color('plain.txt', 'default')
        expect_color('sub', 'brightblue')
        expect_color('video.mp4', 'magenta')

        run(f'ls {fixture}')
        for name in ('archive.zip', 'exec.sh', 'image.png', 'link', 'pipe', 'plain.txt', 'sub', 'video.mp4'):
            check(any(name in line for line in screen.display), 'ls columns entry: ' + name)
        check(sum(1 for line in screen.display if 'video.mp4' in line) == 1, 'ls columns reflowed locally')
        expect_color('archive.zip', 'brightred')
        expect_color('exec.sh', 'brightgreen')
        expect_color('sub', 'brightblue')

        run(f'ls -l {fixture}')
        check(any(re.match(r'^total \d+', line.strip()) for line in screen.display), 'ls -l total line')
        for name, mode_color, name_color in (('archive.zip', 'brightred', 'brightred'),
                                             ('exec.sh', 'brightgreen', 'brightgreen'),
                                             ('image.png', 'brightmagenta', 'brightmagenta'),
                                             ('link', 'brightcyan', 'brightcyan'),
                                             ('pipe', 'brightbrown', 'brightbrown'),
                                             ('plain.txt', 'default', 'default'),
                                             ('sub', 'brightblue', 'brightblue'),
                                             ('video.mp4', 'magenta', 'magenta')):
            index = long_row_index(name)
            check(index >= 0, 'ls -l row: ' + name)
            check(cell(index, 0)[0] == mode_color, 'Mode color for ' + name)
            expect_color(name, name_color, row_number=index)
        link_row = long_row_index('link')
        check('link -> sub' in screen.display[link_row], 'symlink target is retained')
        expect_color('sub', 'brightcyan', row_number=link_row)

        run(f'ls -R {fixture}')
        expect_color(fixture + ':', 'brightblue')
        expect_color(fixture + '/sub:', 'brightblue')

        run(f'ls -a -1 {fixture}')
        check(row('.') and row('..'), 'ls -a lists dot entries')
        expect_color('.', 'brightblue')
        run(f'ls -r -1 {fixture}')
        check(0 <= row_index('video.mp4') < row_index('archive.zip'),
              'ls -r preserves the device reverse order')

        run(f'ls -F {fixture}')
        marker_line = next((line for line in screen.display if 'exec.sh*' in line), '')
        check(all(marker in marker_line for marker in ('exec.sh*', 'link@', 'pipe|', 'sub/')),
              'Explicit -F keeps every type marker: ' + marker_line)
        run(f'ls -p {fixture}')
        dir_line = next((line for line in screen.display if 'sub/' in line), '')
        check('exec.sh*' not in dir_line and 'link@' not in dir_line,
              'Explicit -p keeps only the directory marker')

        run(f'ls -S {fixture}')
        sized = next((line for line in screen.display if 'video.mp4' in line), '')
        check(all(name in sized for name in
                  ('archive.zip', 'exec.sh', 'image.png', 'link', 'pipe', 'plain.txt', 'sub', 'video.mp4')),
              'Uppercase -S is locally reflowed like other sort flags: ' + sized)
        expect_color('sub', 'brightblue')
        run(f'ls -h {fixture}')
        check(any(re.match(r'^total \S+', line.strip()) for line in screen.display),
              'ls -h keeps the device total line')
        check(row('archive.zip'), 'ls -h keeps the device one-per-line layout')
        check(not any('archive.zip' in line and 'exec.sh' in line for line in screen.display),
              'ls -h is not reflowed as a filename list')
        expect_default('archive.zip')

        run(f'ls -m {fixture}')
        comma = 'archive.zip, exec.sh, image.png, link, pipe, plain.txt, sub, video.mp4'
        check(row(comma), 'ls -m keeps the device layout')
        expect_default(comma)
        run(f'ls -i {fixture}')
        check(any(re.match(r'^\d+ archive\.zip$', line.strip()) for line in screen.display),
              'ls -i keeps inode prefixes')
        run(f'ls -s {fixture}')
        check(any(re.match(r'^total \d+', line.strip()) for line in screen.display),
              'ls -s keeps the device total')
        check(any(re.match(r'^\d+ archive\.zip$', line.strip()) for line in screen.display),
              'ls -s keeps size prefixes')
        run(f'ls {fixture}/*.txt')
        check(row(f'{fixture}/plain.txt'), 'globs stay on the device output path')
        run(f'ls {fixture} | wc -l')
        check(any(line.strip() == '8' for line in screen.display), 'piped ls uses the live channel')

        # ---- Text search and large directory classes.
        run(f'find {fixture} -maxdepth 1 -name "*.txt"')
        check(row(f'{fixture}/plain.txt'), 'find output')
        start = time.monotonic()
        run('ls /system/bin | wc -l')
        check(any(re.match(r'^\d+$', line.strip()) for line in screen.display),
              'large /system/bin listing completes')
        check(time.monotonic() - start < 6, 'large directory listing must stay responsive')
        run('seq 1 3000')
        check(row('3000'), 'large output reaches the last line')
        check(time.monotonic() - start < 6, 'large output must stay responsive')

        # ---- OpenHarmony command classes.
        run('bm dump -a | head -3', timeout=20)
        check(any('ID:' in line or 'com.' in line for line in screen.display), 'bm dump output')
        run('param get const.product.model', timeout=20)
        check(any(line.strip() and 'param' not in line.lower() and 'error' not in line.lower()
                  for line in screen.display[:-1]), 'param get output')
        run('aa dump -l | head -3', timeout=20)
        check(any('User ID' in line for line in screen.display), 'aa dump output')
        run('hidumper -e | head -3', timeout=20)
        check(any('-----' in line or 'fault' in line.lower() for line in screen.display), 'hidumper output')
        run('hilog -x | head -3', timeout=15)
        check(any(re.match(r'^\d\d-\d\d \d\d:\d\d:\d\d', line.strip()) for line in screen.display),
              'hilog piped output')
        run('dmesg | head -3', timeout=15)
        check(any(line.strip().startswith('[') for line in screen.display), 'dmesg piped output')

        # ---- Compound commands.
        run("echo hi | sed 's/hi/HI/'")
        check(row('HI'), 'pipeline output')
        run('true && echo AND')
        check(row('AND'), '&& output')
        run('false || echo OR')
        check(row('OR'), '|| output')
        run('echo A; echo B')
        check(row('A') and row('B'), 'semicolon output')
        run('echo SUB=$(echo inner)')
        check(row('SUB=inner'), 'command substitution')
        run('echo x > /dev/null && echo REDIR')
        check(row('REDIR'), 'redirection')
        remote("printf 'write ok\\n' > " + fixture + '/write.tmp')
        run(f'cat {fixture}/write.tmp')
        check(row('write ok'), 'file created by the test is readable')
        run(f'cat {fixture}/plain.txt | grep hello')
        check(row('hello world'), 'pipe between device commands')

        # ---- State: status arrow, cwd, OLDPWD, exported values.
        run('false')
        expect_arrow('red')
        run('echo status=$?')
        check(row('status=1'), 'previous exit status')
        expect_arrow('green')
        local_prompt = serial + ' ' + fixture.rsplit('/', 1)[-1] + ' ->'
        run('cd ' + fixture, local_prompt)
        wait_prompt(local_prompt)
        run('pwd', local_prompt)
        check(row(fixture), 'cwd changed by cd')
        run('cd -', prompt_text)
        check(row('/'), 'cd - prints the restored previous directory')
        run('pwd')
        check(row('/'), 'cd - restored the root directory')
        run('pwd # trailing comment')
        check(row('/'), 'trailing comments keep the status record')
        run('export FOO=state; echo FOO=$FOO')
        check(row('FOO=state'), 'export is visible within one command')
        run('echo NEXT=${FOO:-unset}')
        check(row('NEXT=unset'), 'shell state does not persist across commands')

        # ---- Unicode, ANSI, unknown commands and status 127.
        run("printf '中文✓ %s\\n' OK")
        check(row('中文✓ OK'), 'Unicode output')
        run("printf '\\033[31mRED\\033[0m\\n'")
        red_row = row_index('RED')
        check(red_row >= 0, 'ANSI output is displayed')
        expect_color('RED', 'red', row_number=red_row)
        run('hdc_no_such_command_12345')
        check(any('not found' in line or 'inaccessible' in line for line in screen.display),
              'Unknown command reports a device-shell error')
        expect_arrow('red')
        run('echo unknown=$?')
        check(row('unknown=127'), 'Unknown command status')
        run('LS')
        check(any('not found' in line or 'inaccessible' in line for line in screen.display),
              'Uppercase LS is executed by the device, not rewritten as ls')
        expect_arrow('red')
        run('EXIT')
        check(any('not found' in line or 'inaccessible' in line for line in screen.display),
              'Uppercase EXIT is not treated as the exit builtin')
        run('echo still-here')
        check(row('still-here'), 'A case-mismatched EXIT keeps the session open')

        worst = max((max(values), name) for name, values in timings.items())
        print('classes: ' + ', '.join(f'{name}={max(values):.2f}s' for name, values in sorted(timings.items())))
        print(f'worst baseline command: {worst[1]} {worst[0]:.2f}s')
        send('\x04', .2)
        wait(lambda: '已退出 hdc shell。' in '\n'.join(screen.display), 'Ctrl+D did not exit')
        print(f'PASS: {checks} command-class checks')
    finally:
        if child.isalive():
            child.close(force=True)
        subprocess.run(['hdc', '-t', serial, 'shell', 'rm -rf ' + fixture],
                       capture_output=True, text=True, timeout=15)
