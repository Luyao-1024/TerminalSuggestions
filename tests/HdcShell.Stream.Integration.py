"""Streaming, cancellation, typeahead and cleanup without a device.

Uses isolated file fixtures and the hdc adapter, with a private remote process
group as on the device. No additional probe keys are injected into the editor.
"""
import importlib.util
import os
import pathlib
import shutil
import time

spec = importlib.util.spec_from_file_location('hdc_parity', pathlib.Path(__file__).with_name('HdcShell.Parity.py'))
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)
watch = parity.BIN / 'unknown-device-watch'
watch.write_text("#!/bin/sh\nwhile :; do printf 'UNKNOWN_STREAM_ALIVE\\n'; sleep 1; done\n")
watch.chmod(0o755)
session = parity.Session('pwsh', 'stream')
checks = 0

def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message + '\n' + '\n'.join(session.screen.display) + '\nArtifacts: ' + str(parity.BASE))
    checks += 1

def wait_screen(predicate, message, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        session.pump(.05)
        if predicate():
            return
    check(False, message)

def current():
    return session.screen.display[session.screen.cursor.y].strip()

def prompt(name='fixture'):
    wait_screen(lambda: current() == 'parity ' + name + ' ->', 'The device prompt did not return')

def row(text):
    return any(line.strip() == text for line in session.screen.display)

try:
    session.send("printf 'EAR%s' LY; sleep 2; printf 'LA%s\\n' TE\r", .2)
    wait_screen(lambda: current() == 'EARLY', 'A partial line was held until command exit', 1.5)
    check(current() == 'EARLY', 'Partial output is visible while the command is still running')
    prompt()
    check(row('EARLYLATE'), 'Partial writes retain their exact text and line ending')

    # hdc never forwards host stdin EOF, so a command that reads stdin would
    # otherwise block the session forever. The remote script must hand such
    # commands /dev/null and let them terminate with their natural status.
    start = time.monotonic()
    session.send('cat\r', .1)
    prompt()
    check(time.monotonic() - start < 3, 'A command that reads stdin saw EOF instead of hanging')
    session.send("printf 'STDIN_STATUS=%s\\n' $?\r")
    prompt()
    check(row('STDIN_STATUS=0'), 'A stdin-reading command keeps its natural exit status')
    session.send("printf 'PIPE=%s\\n' \"$(echo hi | cat)\"\r")
    prompt()
    check(row('PIPE=hi'), 'The /dev/null default never replaces stdin supplied by the command itself')

    pid_file = parity.FIX / '.stream_pid'
    session.send("printf '%s' $$ > '" + str(pid_file) + "'; while :; do printf 'TIC%s\\n' K; sleep 1; done\r", .2)
    wait_screen(lambda: row('TICK'), 'A continuous command did not stream')
    pid = int(pid_file.read_text())
    start = time.monotonic()
    session.send('\x03', .1)
    prompt()
    check(time.monotonic() - start < 2, 'Ctrl+C returns promptly after stopping a continuous command')
    end = time.monotonic() + 2
    while True:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            break
        if time.monotonic() >= end:
            check(False, 'The interrupted command left a process group running')
        time.sleep(.05)
    check(True, 'The interrupted shell and pipeline children are gone')
    session.send("printf 'STATUS=%s\\n' $?\r")
    prompt()
    check(row('STATUS=130'), 'The next command sees interrupted status 130')

    session.send('unknown-device-watch\r', .2)
    wait_screen(lambda: row('UNKNOWN_STREAM_ALIVE'), 'Unknown command names did not use the default streaming channel')
    session.send('\x03', .1)
    prompt()
    check(True, 'An arbitrary new command streams and interrupts without a name rule')

    session.send('seq 1 12000\r', .2)
    prompt()
    check(row('12000'), 'Large command output was truncated')

    session.send("cd local; while :; do printf 'CHIL%s\\n' D; sleep 1; done\r", .2)
    wait_screen(lambda: row('CHILD'), 'A compound command did not stream')
    session.send('\x03', .1)
    prompt('local')
    check(True, 'Ctrl+C preserves a directory changed before the interrupted command')
    session.send('cd ..\r')
    prompt()

    # One write, no extra Enter: exercise PSReadLine's read-ahead as well as
    # input arriving while the command is running.
    session.send("sleep 1\rprintf 'QUEU%s\\n' ED\r", .1)
    wait_screen(lambda: row('QUEUED'), 'Typeahead was lost or needed another Enter')
    prompt()
    check(True, 'Typeahead executes once without an extra key or Enter')

    start = time.monotonic()
    session.send('sleep 20\r\x03', .1)
    # Wait for the previous prompt to be replaced and then restored; the
    # snapshot must be empty so an old prompt cannot satisfy the assertion.
    wait_screen(lambda: current() == 'parity fixture ->' and session.state() == ['', 0], 'A Ctrl+C queued with Enter was ignored')
    check(time.monotonic() - start < 2, 'A queued Ctrl+C is handled without an extra press')
    check('@@HDCSHELL_' not in session.log, 'Internal PID/status markers leaked into output')
    check('exception occurred in custom key handler' not in session.log.lower(), 'The editor raised an exception')
    session.send('\x04')
    session.wait('已退出 hdc shell。')
    print(f'PASS: {checks} streaming, cancellation, cleanup and typeahead checks')
finally:
    session.close()
if checks:
    shutil.rmtree(parity.BASE)
