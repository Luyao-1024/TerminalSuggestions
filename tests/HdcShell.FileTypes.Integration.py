"""Device file-type matrix: colors, quoting, symlinks, FIFOs and special files.

python3 tests/HdcShell.FileTypes.Integration.py SERIAL

Covers directories, regular files, executables, archives/images/video,
symlinks (valid, to a file, broken), FIFOs, character/block devices and
binary ELF files. Checks path emphasis, ls type/extension colors, command
results, expected blocking behavior and Ctrl+C recovery.

Creates one fixture under /data/local/tmp and removes it at exit.
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
fixture = '/data/local/tmp/hdc_ft_%d_%d' % (os.getpid(), int(time.time()))
checks = 0


def remote(command, timeout=15):
    result = subprocess.run(['hdc', '-t', serial, 'shell', command],
                            capture_output=True, text=True, timeout=timeout)
    return result.stdout + result.stderr


def exists(path):
    return 'yes' in remote('test -e %s 2>/dev/null && echo yes' % path, 10)


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message + '\n' + '\n'.join(screen.display))
    checks += 1


remote('\n'.join([
    'mkdir -p %s/sub' % fixture,
    "printf 'hello\\n' > %s/plain.txt" % fixture,
    "printf '\\000BINEND\\n' > %s/bin.dat" % fixture,
    "printf '#!/bin/sh\\n' > %s/exec.sh" % fixture,
    'chmod 755 %s/exec.sh' % fixture,
    ': > %s/a.zip' % fixture,
    ': > %s/i.png' % fixture,
    ': > %s/v.mp4' % fixture,
    'ln -s sub %s/linkdir' % fixture,
    'ln -s plain.txt %s/linkfile' % fixture,
    'ln -s missing %s/broken' % fixture,
    'mkfifo %s/fifo 2>/dev/null || true' % fixture,
]))

with tempfile.TemporaryDirectory(prefix='hdc-filetypes-') as folder:
    history = pathlib.Path(folder) / 'history'
    prompt_text = serial + ' / ->'
    startup = (f"Import-Module '{module}'; Set-PSReadLineOption -HistorySavePath '{history}'")
    child = pexpect.spawn('pwsh', ['-NoLogo', '-NoProfile', '-NoExit', '-Command', startup],
                          encoding='utf8', dimensions=(60, 220))
    child.delaybeforesend = 0

    class Terminal(pyte.Screen):
        def write_process_input(self, data):
            child.send(data)

    screen = Terminal(220, 60)
    stream = pyte.Stream(screen)

    def pump(seconds=.03):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                stream.feed(child.read_nonblocking(65536, timeout=min(.01, max(.001, end - time.monotonic()))))
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                return

    def current():
        return screen.display[screen.cursor.y].strip()

    def is_prompt():
        return current().startswith(serial + ' ') and current().endswith('->')

    def wait(predicate, message, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pump()
            if predicate():
                return
        check(False, message)

    def wait_prompt(expected, timeout=20):
        wait(lambda: current() == expected, 'Prompt did not return: ' + expected, timeout)

    def row_index(value, after=-1):
        for index, line in enumerate(screen.display):
            if index > after and line.strip() == value:
                return index
        return -1

    def long_row_index(name):
        for index, line in enumerate(screen.display):
            if not re.match(r'^[-dlbcps][rwxsStT-]{9}\s', line):
                continue
            entry = line.split(' -> ', 1)[0].rstrip() if ' -> ' in line else line.rstrip()
            if entry.rsplit(None, 1)[-1] == name:
                return index
        return -1

    def cell(row, column):
        return (screen.buffer[row][column].fg, screen.buffer[row][column].underscore)

    def cells(needle, row=None):
        if row is None:
            row = next((i for i, line in enumerate(screen.display) if needle in line), -1)
        if row < 0:
            return []
        start = screen.display[row].find(needle)
        return [] if start < 0 else [cell(row, start + i) for i in range(len(needle))]

    def expect_color(needle, color, underline=False, row=None):
        values = cells(needle, row)
        check(bool(values), 'Missing text: ' + needle)
        check(all(fg == color and under == underline for fg, under in values),
              'Color for %r expected %s%s, got %s' % (needle, color,
                                                      ' + underline' if underline else '',
                                                      sorted(set(values))))

    def select_all():
        child.send('\x01'); child.send('\x0b')

    def type_line(text):
        child.send('\x0c'); wait_prompt(prompt_text)
        child.send(text)
        wait(lambda: screen.display[screen.cursor.y].rstrip().endswith(text), 'Input not rendered: ' + text)
        pump(.15)
        return screen.cursor.y

    def cancel_input():
        child.send('\x03'); pump(.15); wait_prompt(prompt_text)

    def run(command, expected=None, timeout=15):
        expected = expected or prompt_text
        wait(lambda: is_prompt(), 'Device prompt is not ready')
        if current() != expected:
            child.send('cd /')
            wait_prompt(prompt_text)
        child.send('\x0c'); wait_prompt(expected)
        echo = (expected + ' ' + command).strip()
        start = time.monotonic()
        child.send(command + '\r')
        started = False
        end = start + timeout
        while time.monotonic() < end:
            pump()
            if not started:
                started = any(line.strip() == echo for line in screen.display)
            if started and current() == expected:
                return
        check(False, 'Timed out: ' + command)

    def interrupt(command, timeout=12):
        """Start a blocking command, verify it blocks, then Ctrl+C it."""
        child.send('\x0c'); wait_prompt(prompt_text)
        child.send(command + '\r'); pump(1.5)
        check(current() != prompt_text, 'Expected blocking command: ' + command)
        start = time.monotonic()
        child.send('\x03')
        wait_prompt(prompt_text, timeout)
        check(time.monotonic() - start < timeout, 'Ctrl+C did not recover: ' + command)

    try:
        wait(lambda: 'PS ' in ''.join(screen.display), 'PowerShell did not start')
        child.send("Enter-HdcShell -Serial '" + serial.replace("'", "''") + "'\r")
        wait_prompt(prompt_text)

        # ---- Input emphasis: existence follows symlinks like zsh (-L || -e).
        for text, needle, color, underline in [
                (f'cat {fixture}/plain.txt', f'{fixture}/plain.txt', '00ffff', True),
                (f'cat {fixture}/broken', f'{fixture}/broken', '00ffff', True),
                (f'cd {fixture}/linkdir', f'{fixture}/linkdir', '00ffff', True),
                (f'cd {fixture}/linkfile', f'{fixture}/linkfile', '00ffff', True),
                (f'cd {fixture}/fifo', f'{fixture}/fifo', '00ffff', True),
                (f'cat {fixture}/missing', f'{fixture}/missing', 'default', False)]:
            type_line(text)
            expect_color(needle, color, underline)
            cancel_input()

        # Only a complete device command is green; "l" is not "ls".
        type_line('l')
        check(cells('l')[0][0] != 'green', 'An incomplete command prefix is not green')
        cancel_input()
        type_line('ls')
        check(cells('ls')[0][0] == 'green', 'An exact device command is green')
        cancel_input()
        # Only an exact path is emphasized; "su" is a prefix of "sub".
        type_line(f'cd {fixture}/su')
        expect_color(f'{fixture}/su', 'default', False)
        cancel_input()
        type_line(f'cd {fixture}/sub')
        expect_color(f'{fixture}/sub', '00ffff', True)
        cancel_input()

        # A file created by the previous command must be visible to path
        # emphasis on the next input line, despite the 10-second cache.
        run(f'touch {fixture}/fresh.txt')
        type_line(f'cat {fixture}/fresh.txt')
        expect_color(f'{fixture}/fresh.txt', '00ffff', True)
        cancel_input()

        # ---- Long listing colors for every fixture type.
        run(f'ls -l {fixture}')
        for name, color in [('a.zip', 'brightred'), ('i.png', 'brightmagenta'),
                            ('v.mp4', 'magenta'), ('exec.sh', 'brightgreen'),
                            ('linkdir', '00ffff'), ('linkfile', '00ffff'),
                            ('broken', '00ffff'), ('fifo', 'brightbrown'),
                            ('plain.txt', 'default'), ('sub', 'brightblue')]:
            index = long_row_index(name)
            check(index >= 0, 'ls -l missing entry: ' + name)
            expect_color(name, color, row=index)

        # ---- Real device special files.
        if exists('/dev/null'):
            run('ls -l /dev/null')
            index = long_row_index('/dev/null')
            check(index >= 0, 'ls -l /dev/null')
            expect_color('/dev/null', 'brightbrown', row=index)
        if exists('/dev/loop0'):
            run('ls -l /dev/loop0')
            index = long_row_index('/dev/loop0')
            check(index >= 0, 'ls -l /dev/loop0')
            expect_color('/dev/loop0', 'brightbrown', row=index)

        # ---- Commands on each file type.
        run(f'cat {fixture}/plain.txt')
        check(row_index('hello') >= 0, 'cat regular file')
        run(f'base64 {fixture}/plain.txt')
        check(any(line.strip() == 'aGVsbG8K' for line in screen.display), 'base64 regular file')
        run(f'cat {fixture}/bin.dat')
        check(any('二进制内容' in line or 'AEJJTkVORAo=' in line for line in screen.display),
              'Simple binary cat is displayed as base64, including NUL bytes')
        run(f'cat {fixture}/missing')
        check(any('No such file' in line or 'not found' in line for line in screen.display),
              'cat error is decoded through base64')
        run('echo cat_rc=$?')
        check(row_index('cat_rc=1') >= 0, 'cat missing file keeps status 1')
        run(f'readlink {fixture}/linkfile')
        check(any(line.strip() == 'plain.txt' for line in screen.display), 'readlink symlink')
        if remote('command -v file >/dev/null 2>&1; echo $?').strip().endswith('0'):
            run(f'file {fixture}/fifo')
            check(any('fifo' in line for line in screen.display), 'file detects FIFO')
            run(f'file {fixture}/linkfile')
            check(any('symbolic link' in line for line in screen.display), 'file detects symlink')
            run(f'file {fixture}/broken')
            check(any('broken symbolic link' in line for line in screen.display), 'file detects broken symlink')
        run(f'stat {fixture}/fifo')
        check(any(fixture + '/fifo' in line for line in screen.display), 'stat FIFO')
        if remote('command -v timeout >/dev/null 2>&1; echo $?').strip().endswith('0'):
            run(f'timeout 1 cat {fixture}/fifo')
            run('echo fifo_rc=$?')
            check(row_index('fifo_rc=124') >= 0, 'timeout stops a FIFO read with status 124')
        if exists('/dev/null'):
            run('cat /dev/null')
            check(current() == prompt_text, 'cat /dev/null returns')
        child.send('\x0c'); wait_prompt(prompt_text)
        child.send(f'cd {fixture}/linkdir && pwd\r')
        sub_prompt = serial + ' linkdir ->'
        wait_prompt(sub_prompt)
        check(any(line.strip() == fixture + '/linkdir' for line in screen.display),
              'cd follows a directory symlink')
        child.send('cd /\r'); wait_prompt(prompt_text)
        for bad in ('linkfile', 'fifo'):
            run(f'cd {fixture}/{bad}')
            check(current() == prompt_text, 'cd to non-directory keeps cwd: ' + bad)
        if exists('/system/bin/init'):
            # The small bin.dat case above covers direct binary transport; the
            # large ELF is checked through base64 to keep the terminal fast.
            run('base64 /system/bin/init | wc -c', timeout=25)
            check(any(line.strip().isdigit() and int(line.strip()) > 100000 for line in screen.display),
                  'base64 carries the large ELF')

        # ---- Expected blocking files recover with Ctrl+C, then stay usable.
        interrupt(f'cat {fixture}/fifo')
        if exists('/dev/zero'):
            interrupt('cat /dev/zero')
        run('echo filetypes_alive')
        check(row_index('filetypes_alive') >= 0, 'Session remains usable after interrupts')
        # Output styles must not inherit SGR state from the interrupted reads.
        run(f'ls -l {fixture}')
        index = long_row_index('sub')
        check(index >= 0, 'ls -l after interrupts')
        expect_color('sub', 'brightblue', row=index)

        # Exit the enhanced shell normally so its persistent hdc session is
        # disposed instead of being orphaned by the pexpect teardown.
        child.send('\x04')
        wait(lambda: '已退出 hdc shell。' in '\n'.join(screen.display), 'Ctrl+D did not exit', 10)
        print(f'PASS: {checks} file-type color and command checks')
    finally:
        if child.isalive():
            child.close(force=True)
        subprocess.run(['hdc', '-t', serial, 'shell', 'rm -rf ' + fixture],
                       capture_output=True, text=True, timeout=15)
