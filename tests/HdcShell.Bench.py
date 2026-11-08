"""Per-command latency benchmark for the enhanced hdc shell.

python3 tests/HdcShell.Bench.py SERIAL

Compares three execution paths with medians over repeated runs:
  direct   - hdc -t SERIAL shell CMD (a new hdc process, stdin=/dev/null)
  raw      - interactive `hdc -t SERIAL shell` in a pty (persistent shell)
  enhanced - Enter-HdcShell in a pty; times only Enter -> next prompt, after
             the typed line and its path highlighting have been rendered.

The enhanced input-render time (sending the whole line until it is drawn) is
reported separately, so typing/highlight cost is not mixed into execution.

stdin-reading commands are measured only in the enhanced session: direct hdc
does not forward EOF and raw mode waits for terminal input. The script creates
one fixture under /data/local/tmp and removes it at exit.
"""
import os
import pathlib
import re
import statistics
import subprocess
import sys
import tempfile
import time

import pexpect
import pyte
from wcwidth import wcswidth

root = pathlib.Path(__file__).resolve().parent.parent
serial = sys.argv[1]
module = os.environ.get('HDC_TEST_MODULE', str(root / 'TerminalSuggestions/TerminalSuggestions.psd1'))
fixture = '/data/local/tmp/hdc_bench_%d_%d' % (os.getpid(), int(time.time()))

# (category, label, command, iterations). stdin commands have no direct/raw run.
COMMANDS = [
    ('trivial', 'echo', 'echo hello', 7),
    ('trivial', 'pwd', 'pwd', 7),
    ('trivial', 'true', 'true', 7),
    ('trivial', "printf", "printf 'TXT\\n'", 7),
    ('file', 'cat file', f'cat {fixture}/plain.txt', 7),
    ('file', 'head file', f'head -1 {fixture}/plain.txt', 7),
    ('file', 'tail file', f'tail -1 {fixture}/plain.txt', 7),
    ('file', 'grep file', f'grep hello {fixture}/plain.txt', 7),
    ('file', 'sed file', f'sed -n 1p {fixture}/plain.txt', 7),
    ('file', 'wc file', f'wc -l {fixture}/plain.txt', 7),
    ('file', 'sort file', f'sort {fixture}/plain.txt', 7),
    ('stdin', 'cat', 'cat', 7),
    ('stdin', 'wc', 'wc', 7),
    ('stdin', 'head', 'head', 7),
    ('stdin', 'grep', 'grep x', 7),
    ('stdin', 'read', 'read line', 7),
    ('listing', 'ls', f'ls {fixture}', 7),
    ('listing', 'ls -1', f'ls -1 {fixture}', 7),
    ('listing', 'ls -l', f'ls -l {fixture}', 7),
    ('listing', 'ls -R', f'ls -R {fixture}', 7),
    ('listing', 'ls -a', f'ls -a {fixture}', 7),
    ('listing', 'ls -S', f'ls -S {fixture}', 7),
    ('listing', 'ls -m', f'ls -m {fixture}', 7),
    ('listing', 'ls system/bin', 'ls /system/bin | wc -l', 5),
    ('search', 'find', f"find {fixture} -maxdepth 1 -name '*.txt'", 7),
    ('ohos', 'bm dump', 'bm dump -a | head -3', 4),
    ('ohos', 'param get', 'param get const.product.model', 4),
    ('ohos', 'aa dump', 'aa dump -l | head -3', 4),
    ('ohos', 'hidumper', 'hidumper -e | head -3', 4),
    ('ohos', 'hilog', 'hilog -x | head -3', 4),
    ('ohos', 'dmesg', 'dmesg | head -3', 4),
    ('compound', 'pipe', 'echo hi | cat', 7),
    ('compound', 'and', 'true && echo AND', 7),
    ('compound', 'or', 'false || echo OR', 7),
    ('compound', 'semicolon', 'echo A; echo B', 7),
    ('compound', 'substitution', 'echo SUB=$(echo inner)', 7),
    ('compound', 'redirect', 'echo x > /dev/null && echo REDIR', 7),
    ('state', 'false', 'false', 7),
    ('state', 'export', 'export FOO=state; echo $FOO', 7),
    ('large', 'seq pipe', 'seq 1 3000 | tail -1', 5),
    ('large', 'seq 1000', 'seq 1 1000', 5),
    ('unicode', 'unicode', "printf '中文✓\\n'", 7),
    ('unicode', 'ansi', "printf '\\033[31mRED\\033[0m\\n'", 7),
]


def setup_fixture():
    subprocess.run(['hdc', '-t', serial, 'shell', '\n'.join([
        'mkdir -p %s/sub' % fixture,
        "printf 'hello world\\n' > %s/plain.txt" % fixture,
        "printf '#!/bin/sh\\n' > %s/exec.sh" % fixture,
        'chmod 755 %s/exec.sh' % fixture,
        ': > %s/archive.zip' % fixture,
        ': > %s/image.png' % fixture,
        'ln -s sub %s/link' % fixture,
        'mkfifo %s/pipe 2>/dev/null || true' % fixture,
    ])], capture_output=True, text=True, timeout=20)


def cleanup_fixture():
    subprocess.run(['hdc', '-t', serial, 'shell', 'rm -rf ' + fixture],
                   capture_output=True, text=True, timeout=20)


class PtySession:
    def __init__(self, argv, prompt, width=200, height=60):
        self.child = pexpect.spawn(argv[0], argv[1:], encoding='utf8', timeout=30,
                                   dimensions=(height, width))
        # pexpect sleeps 50 ms before every send by default. That inflates both
        # the measured Enter->prompt window and each DSR response, so it must
        # be off for a meaningful terminal-side measurement.
        self.child.delaybeforesend = 0
        child = self.child

        class Terminal(pyte.Screen):
            def write_process_input(self, data):
                child.send(data)

        self.screen = Terminal(width, height)
        self.stream = pyte.Stream(self.screen)
        self.prompt = prompt

    def pump(self, seconds=.02):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                self.stream.feed(self.child.read_nonblocking(65536, timeout=.01))
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                return

    def current(self):
        return self.screen.display[self.screen.cursor.y].strip()

    def wait(self, predicate, message, timeout=30):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump()
            if predicate():
                return
        raise RuntimeError(message + '\n' + '\n'.join(self.screen.display))

    def wait_prompt(self):
        self.wait(lambda: self.current() == self.prompt,
                  'prompt did not return: ' + self.prompt)

    def close(self):
        self.child.close(force=True)


def direct(cmd, timeout=30):
    start = time.monotonic()
    subprocess.run(['hdc', '-t', serial, 'shell', cmd], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    return time.monotonic() - start


def measure(session, cmd):
    """Return (exec_seconds, render_seconds_or_None) for one command."""
    session.wait_prompt()
    start = time.monotonic()
    session.child.send(cmd)

    def rendered():
        # The cursor sits right after the typed text; inline history
        # prediction may extend the visible line beyond it.
        needle = session.prompt + ' ' + cmd
        width = wcswidth(needle)
        for index in range(len(session.screen.display) - 1, -1, -1):
            if session.prompt in session.screen.display[index]:
                return (session.screen.display[index].startswith(needle) and
                        session.screen.cursor.y == index and
                        session.screen.cursor.x >= width)
        return False

    session.wait(rendered, 'input was not rendered: ' + cmd, 30)
    rendered = time.monotonic()
    session.pump(.05)  # let path highlighting finish before Enter
    before_enter = time.monotonic()
    session.child.send('\r')
    session.wait_prompt()
    return time.monotonic() - before_enter, rendered - start


def median(values):
    return statistics.median(values) * 1000 if values else None


def report(label, direct_ms, raw_ms, enhanced_exec, enhanced_render):
    def cell(value):
        return '—' if value is None else f'{value:.0f}'
    rows.append((label, cell(direct_ms), cell(raw_ms), cell(enhanced_exec), cell(enhanced_render)))


rows = []
results = {}
setup_fixture()
try:
    # Direct non-interactive path.
    direct_ms = {}
    for _, label, cmd, iterations in COMMANDS:
        if label in ('cat', 'wc', 'head', 'grep', 'read'):
            direct_ms[label] = None
            continue
        direct(cmd)
        direct_ms[label] = median([direct(cmd) for _ in range(iterations)])

    # Raw persistent hdc shell.
    raw = PtySession(['hdc', '-t', serial, 'shell'], '#')
    raw_ms = {}
    try:
        raw.wait_prompt()
        for _, label, cmd, iterations in COMMANDS:
            if label in ('cat', 'wc', 'head', 'grep', 'read'):
                raw_ms[label] = None
                continue
            raw.wait_prompt()
            raw.child.send(cmd + '\r')
            raw.wait_prompt()  # warm-up, discarded
            values = []
            for _ in range(iterations):
                values.append(measure(raw, cmd)[0])
            raw_ms[label] = median(values)
    finally:
        raw.close()

    # Enhanced session: same pty/pyte harness, module in the repo or installed.
    with tempfile.TemporaryDirectory(prefix='hdc-bench-') as temp:
        startup = (f"Import-Module '{module}'; Set-PSReadLineOption -HistorySavePath '{temp}/history'")
        enhanced = PtySession(['pwsh', '-NoLogo', '-NoProfile', '-NoExit', '-Command', startup],
                              serial + ' / ->')
        try:
            enhanced.wait(lambda: 'PS ' in ''.join(enhanced.screen.display), 'pwsh did not start')
            enhanced.child.send(f"Enter-HdcShell -Serial '{serial}'\r")
            enhanced.wait_prompt()
            for _, label, cmd, iterations in COMMANDS:
                exec_values, render_values = [], []
                measure(enhanced, cmd)  # warm-up, discarded
                enhanced.wait_prompt()
                for _ in range(iterations):
                    exec_s, render_s = measure(enhanced, cmd)
                    exec_values.append(exec_s)
                    render_values.append(render_s)
                    enhanced.wait_prompt()
                results[label] = {
                    'direct_ms': direct_ms[label],
                    'raw_ms': raw_ms[label],
                    'enhanced_ms': median(exec_values),
                    'enhanced_render_ms': median(render_values),
                }
        finally:
            enhanced.close()
finally:
    cleanup_fixture()

print('| category | command | direct (ms) | raw (ms) | enhanced exec (ms) | enhanced input render (ms) |')
print('|---|---|---:|---:|---:|---:|')
current_category = None
for category, label, cmd, iterations in COMMANDS:
    data = results[label]
    if category != current_category:
        current_category = category
    print('| %s | `%s` | %s | %s | %s | %s |' % (
        category,
        cmd.replace(fixture, '<fixture>'),
        '—' if data['direct_ms'] is None else f"{data['direct_ms']:.0f}",
        '—' if data['raw_ms'] is None else f"{data['raw_ms']:.0f}",
        f"{data['enhanced_ms']:.0f}",
        f"{data['enhanced_render_ms']:.0f}",
    ))
