"""Compare path spans/keys with local Oh My Zsh and require bright-cyan paths.

Uses the isolated file tree/hdc adapter from HdcShell.Parity.py. Reads rendered
terminal attributes as well as buffers, so ANSI sequences alone cannot pass.
"""
import importlib.util
import pathlib
import shutil
import sys

spec = importlib.util.spec_from_file_location('hdc_parity', pathlib.Path(__file__).with_name('HdcShell.Parity.py'))
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)

cases = {
    'existing': ['cd local'],
    'missing': ['cd local-no-such-directory'],
    'delete_and_restore': ['cd local', 'x', '\x7f'],
    'quoted': ['cd "space dir"'],
    'mixed_quotes': ['cd ./"space dir"'],
    'prefix': ['cd loca', ' '],
    'escaped': ['cd space\\ dir'],
    'file': ['cat plain\\ file'],
    'multiple': ['ls local log missing'],
    'absolute': ['cd ' + str(parity.FIX / 'local')],
    'relative': ['cd ./local'],
    'home': ['cd ~'],
    'home_quoted': ['cd "$HOME"'],
    'completion': ['cd loca', '\t'],
    'history': ['ls local\r', '\x1b[A'],
    'cwd': ['cd local\r', 'cd ../log'],
}
if sys.argv[1:]:
    cases = {name: cases[name] for name in sys.argv[1:]}
results = {}
checks = 0
failures = []
for label, events in cases.items():
    results[label] = {}
    for kind in ('zsh', 'pwsh'):
        session = parity.Session(kind, 'highlight-' + label)
        try:
            checkpoints = []
            for event in events:
                session.send(event)
                line, cursor = session.state()
                # A submitted command has an empty new input line.
                if not line:
                    checkpoints.append((line, cursor, []))
                    continue
                row = session.screen.cursor.y
                display = session.screen.display[row]
                start = display.find(line)
                if start < 0:
                    raise AssertionError(f'{kind} {label}: input not visible: {line!r}\n{display}')
                attributes = [session.screen.buffer[row][start + i].underscore for i in range(len(line))]
                if kind == 'pwsh':
                    for i, underlined in enumerate(attributes):
                        foreground = session.screen.buffer[row][start + i].fg
                        if (foreground == 'brightcyan') != underlined:
                            raise AssertionError(f'{label}: expected path color at {i}={underlined}, got {foreground}; {line!r}')
                checkpoints.append((line, cursor, attributes))
            if 'exception occurred in custom key handler' in session.log.lower():
                raise AssertionError(session.log[-3000:])
            results[label][kind] = checkpoints
        finally:
            session.close()
    if results[label]['zsh'] != results[label]['pwsh']:
        failures.append(label)
        print(f'FAIL {label}: {results[label]}', flush=True)
        continue
    checks += len(events)
    print('PASS', label, flush=True)

if failures:
    raise AssertionError(f'{len(failures)} mismatches: {failures}; artifacts: {parity.BASE}')
shutil.rmtree(parity.BASE)
print(f'PASS: {len(cases)} path-color flows, {checks} matching underline/buffer/cursor checkpoints; cyan only on emphasized paths')
