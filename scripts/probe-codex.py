#!/usr/bin/env python3
"""Read-only app-server probe. Never prints credentials or conversation contents."""
import json, subprocess, selectors, time, shutil
command = [shutil.which('codex'), 'app-server', '--listen', 'stdio://']
process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
def send(message):
    process.stdin.write(json.dumps(message) + '\n'); process.stdin.flush()
def read(expected, timeout=15):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if not selector.select(max(0,deadline-time.monotonic())): break
        line=process.stdout.readline()
        if not line: break
        try: message=json.loads(line)
        except: continue
        if message.get('id')==expected: return message
    return {'error':{'message':'No response before timeout'}}
try:
    send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'yukino_tools','title':'Yukino Tools','version':'0.3.0'}}})
    initialized=read(1)
    print('initialize:', 'ok' if 'result' in initialized else initialized.get('error'))
    if 'result' in initialized:
        send({'method':'initialized','params':{}})
        send({'id':2,'method':'account/rateLimits/read'})
        response=read(2)
        result=response.get('result',{})
        print(json.dumps({'rateLimits':result.get('rateLimits'),'rateLimitsByLimitId':result.get('rateLimitsByLimitId'),'error':response.get('error')},ensure_ascii=False))
finally:
    process.terminate()
    try: process.wait(timeout=2)
    except subprocess.TimeoutExpired: process.kill();process.wait()
