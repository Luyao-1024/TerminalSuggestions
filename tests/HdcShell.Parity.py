"""Compare identical keystrokes with the user's actual Oh My Zsh configuration.

Requires Linux/macOS, zsh, pwsh, pexpect and pyte. A local hdc test adapter gives
both editors identical temporary files and records accepted commands; the real
device integration test is separate. Reads buffers without injecting probe keys.
All spaces, escapes, cursor offsets and command submission counts are compared.
"""
import base64,json,os,pathlib,pexpect,pyte,sys,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parent.parent
BASE=pathlib.Path(tempfile.mkdtemp(prefix='hdc-parity-'))
FIX=BASE/'fixture';FIX.mkdir()
for name in ['local','log','lost+found','space dir','space two','space dir/child','space dir/check']:(FIX/name).mkdir()
(FIX/'plain file').write_text('')
(FIX/'plain-other').write_text('')
BIN=BASE/'bin';BIN.mkdir()
shim=BIN/'hdc'
shim.write_text('''#!/usr/bin/python3
import os,sys,subprocess,signal
try:
    import ctypes
    ctypes.CDLL(None).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG: no orphan on test teardown
except Exception:
    pass
args=sys.argv[1:]
q=' '.join(args[args.index('shell')+1:])
if q.startswith('IFS=:'): print('/bin/cat\\n/bin/echo\\n/bin/ls');sys.exit(0)
# hdc keeps the remote stdin channel open for the whole command, so closing the
# local client stdin never gives the remote command EOF. Model that here.
read_fd,write_fd=os.pipe()
p=subprocess.Popen(['/bin/sh','-c',q],cwd=os.environ['PARITY_FIXTURE'],stdin=read_fd,start_new_session=True)
os.close(read_fd)
def stop(signum,frame):
    try: os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError: pass
    os.close(write_fd)
    sys.exit(128+signum)
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGHUP,stop)
rc=p.wait()
os.close(write_fd)
sys.exit(rc)
''');shim.chmod(0o755)
CS='''using System;using System.IO;using System.Reflection;using System.Text;using System.Threading;
public static class ParityProbe {static Timer timer;static string last;
public static void Start(Type type,string path){var method=type.GetMethod("GetBufferState",new Type[]{typeof(string).MakeByRefType(),typeof(int).MakeByRefType()});timer=new Timer(_=>{try{object[] a={null,0};method.Invoke(null,a);var line=a[0] as string;if(line==null)return;var data=Convert.ToBase64String(Encoding.UTF8.GetBytes(line))+":"+a[1]+"\\n";if(data!=last){File.AppendAllText(path,data);last=data;}}catch{}},null,0,5);}}
'''
class Session:
 def __init__(self,kind,tag):
  self.kind=kind;self.dir=BASE/(kind+'-'+tag);self.dir.mkdir();self.snapshot=self.dir/'snapshot';self.accepted=self.dir/'accepted'
  env=dict(os.environ,HISTFILE=str(self.dir/'history'),ZSH_COMPDUMP=str(self.dir/'zcompdump'),PARITY_FIXTURE=str(FIX),PATH=str(BIN)+os.pathsep+os.environ['PATH'],DISABLE_AUTO_UPDATE='true')
  if kind=='zsh':
   setup=f"source \"$HOME/.zshrc\"\nPROMPT='T> '; RPROMPT=''; fc -p '{self.dir}/history'; autoload -Uz add-zle-hook-widget; _parity_snapshot() {{ print -rn -- \"$BUFFER\"$'\\0'\"$CURSOR\"$'\\0' >> '{self.snapshot}'; }}; _parity_finish() {{ print -rn -- \"$BUFFER\"$'\\0' >> '{self.accepted}'; }}; add-zle-hook-widget line-init _parity_snapshot; add-zle-hook-widget line-pre-redraw _parity_snapshot; add-zle-hook-widget line-finish _parity_finish; print -s -- 'echo alpha beta'; print -s -- 'echo /data/local/tmp'; print -r -- PARITY_READY"
   (self.dir/'.zshrc').write_text(setup)
   env['ZDOTDIR']=str(self.dir)
   self.child=pexpect.spawn('zsh',['-i'],env=env,cwd=str(FIX),encoding='utf8',dimensions=(35,120))
  else:
   histdir=self.dir/'HdcShellHistory';histdir.mkdir();(histdir/(str(FIX).replace('%','%25').replace('/','%2F')+'.txt')).write_text('echo alpha beta\necho /data/local/tmp\n')
   (self.dir/'Probe.cs').write_text(CS)
   startup=f"Import-Module '{ROOT}/TerminalSuggestions/TerminalSuggestions.psd1'; Set-PSReadLineOption -HistorySavePath '{self.dir}/history'; Add-Type -Path '{self.dir}/Probe.cs'; [ParityProbe]::Start([Microsoft.PowerShell.PSConsoleReadLine],'{self.snapshot}'); & (Get-Module TerminalSuggestions) {{ $script:ParityHistory='{self.accepted}'; $script:ParityEditor=(Get-Command Enable-HdcShellEditor).ScriptBlock; function script:Enable-HdcShellEditor {{ & $script:ParityEditor; $script:ParityHandler=(Get-PSReadLineOption).AddToHistoryHandler; Set-PSReadLineOption -AddToHistoryHandler {{ param($line); [IO.File]::AppendAllText($script:ParityHistory, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($line))+\"`n\"); $script:ParityHandler.Invoke($line) }} }} }}"
   self.child=pexpect.spawn('pwsh',['-NoLogo','-NoProfile','-NoExit','-Command',startup],env=env,cwd=str(FIX),encoding='utf8',dimensions=(35,120))
  session=self
  class Screen(pyte.Screen):
   def write_process_input(self,data):session.child.send(data)
  self.screen=Screen(120,35);self.stream=pyte.Stream(self.screen);self.log=''
  if kind=='zsh':
   self.wait('PARITY_READY')
  else:
   self.wait('PS ')
   self.send("Enter-HdcShell -Serial parity\r",.7);self.wait('parity fixture')
   self.pump(.3)
   # Seed the same prefix history without executing a command in either shell.
   # This is added via the directory history file before the first remote read.
  self.pump(.3)
  self.accepted.write_bytes(b'')
 def pump(self,sec=.15):
  end=time.monotonic()+sec
  while time.monotonic()<end:
   try:
    data=self.child.read_nonblocking(65536,timeout=.05);self.log+=data;self.stream.feed(data)
   except pexpect.TIMEOUT:pass
   except pexpect.EOF:break
 def wait(self,text):
  end=time.monotonic()+15
  while time.monotonic()<end:
   self.pump(.1)
   if text in self.log:return
  raise RuntimeError(self.kind+' startup failed: '+self.log[-3000:])
 def send(self,data,sec=.45):self.child.send(data);self.pump(sec)
 def state(self):
  if not self.snapshot.exists():return None
  data=self.snapshot.read_bytes()
  if self.kind=='zsh':
   parts=data.split(b'\0');return [parts[-3].decode(),int(parts[-2])] if len(parts)>=3 else None
  lines=data.splitlines()
  for line in reversed(lines):
   try:
    text,cursor=line.rsplit(b':',1);return [base64.b64decode(text).decode(),int(cursor)]
   except Exception:continue
 def commands(self):
  data=self.accepted.read_bytes()
  if self.kind=='zsh':return [x.decode() for x in data.split(b'\0') if x]
  return [base64.b64decode(x).decode() for x in data.splitlines() if x]
 def close(self):
  (self.dir/'terminal.log').write_text(self.log);self.child.close(force=True)

CASES={
'history_right':['echo alph','\x1b[C'],
'history_word':['echo alph','\x1b[1;5C'],
'history_word_path':['echo /da','\x1b[1;5C'],
'history_ctrl_e':['echo alph','\x01','\x05','\x05'],
'history_ctrl_f':['echo alph','\x01','\x06'],
'history_up_down':['echo al','\x1b[A','\x1b[B'],
'menu_type':['cd lo','\t','\t','X'],
'menu_escape':['cd lo','\t','\t','\x1b'],
'menu_ctrlg':['cd lo','\t','\t','\x07'],
'menu_ctrlc':['cd lo','\t','\t','\x03'],
'menu_expand':['cd l','\t','\t','\t'],
'directory_quote':['cd "space d','\t','"'],
'directory_enter':['cd loca','\t','\r'],
'file_enter':['cat plain\\ f','\t','\r'],
'slash_twice':['cd loca','\t','/'],
'move_after_completion':['cd loca','\t','\x02','\x06',' '],

'unique_dir':['cd loca','\t'],
'file_space':['cat plain\\ f','\t'],
'quoted_dir':['cd "space d','\t'],
'quoted_file':['cat "plain f','\t'],
'escaped_dir':['cd space\\ d','\t'],
'dir_then_space':['cd loca','\t',' '],
'menu_first':['cd lo','\t'],
'menu_choose':['cd lo','\t','\t','\x1b[Z'],
'menu_accept':['cd lo','\t','\t','\r'],
'menu_execute':['cd lo','\t','\t','\r','\r'],
'menu_space':['cd lo','\t','\t',' '],
'file_then_word':['cat plain\\ f','\t','NEXT','\r'],
'motion_forward':['echo alpha beta','\x01','\x1b[1;5C'],
'motion_backward':['echo alpha beta','\x1b[1;5D'],
}
CASES.update({
'midword_match':['cd locl','\x02','\t'],
'midword_no_match':['cd loX','\x02','\t'],
'midword_quoted':['cd "locl"','\x1b[D\x1b[D','\t'],
'existing_next_argument':['cat plain\\ f more','\x1b[D'*5,'\t'],
'continue_directory':['cd space\\ d','\t','chil','\t','\r'],
})
def run_cases():
 selected=sys.argv[1:]
 cases={name:CASES[name] for name in selected} if selected else CASES
 results={}
 steps=0
 failures=[]
 for label,events in cases.items():
  results[label]={}
  for kind in ('zsh','pwsh'):
   session=Session(kind,label)
   try:
    states=[]
    for event in events:
     session.send(event)
     states.append(session.state())
    results[label][kind]={'states':states,'accepted':session.commands()}
   finally:
    session.close()
  steps+=len(events)
  if results[label]['zsh']!=results[label]['pwsh']:
   failures.append(label)
   print('FAIL',label,json.dumps(results[label],ensure_ascii=False),flush=True)
  else:
   print('PASS',label,flush=True)
 (BASE/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
 if failures:
  raise SystemExit(f'{len(failures)} mismatches; artifacts: {BASE}')
 print(f'PASS: {len(cases)} identical keyboard sequences, {steps} buffer/cursor checkpoints; submitted command text also identical')
 import shutil
 shutil.rmtree(BASE)

if __name__=='__main__': run_cases()
