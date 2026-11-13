#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import json
import os
from pathlib import Path
import sys
import time

state_path = Path(os.environ['CODEX_FIXTURE_STATE'])
mode = os.environ.get('CODEX_FIXTURE_MODE', 'success')
state = json.loads(state_path.read_text())
state['processes'] += 1
state['pids'].append(os.getpid())
state_path.write_text(json.dumps(state))
thread_id = '01a1d60a-b26a-7930-b8c8-e312607a60ea'


def thread():
    state = json.loads(state_path.read_text())
    turns = []
    if state.get('woken') and mode != 'queue-only':
        text = state['prompt']
        if mode == 'changed-text':
            text = text.replace('e\u0301', '\u00e9')
        client_id = 'different' if mode == 'wrong-client' else state['clientId']
        turns = [{'id': 'actual-turn', 'items': [{'type': 'userMessage', 'id': 'separate-item-id', 'clientId': client_id, 'content': [{'type': 'text', 'text': text}]}]}]
    return {'thread': {'id': thread_id, 'status': {'type': 'notLoaded'}, 'turns': turns}}


for line in sys.stdin:
    message = json.loads(line)
    method = message['method']
    state = json.loads(state_path.read_text())
    state['methods'].append(method)
    state_path.write_text(json.dumps(state))
    if 'id' not in message:
        continue
    params = message['params']
    if method == 'initialize':
        result = {}
    elif method == 'thread/start':
        assert params == {'cwd': os.path.expanduser('~'), 'config': {'thread_unload_delay_secs': 0}}
        result = {'thread': {'id': thread_id}}
    elif method == 'thread/name/set':
        assert params['name'] == 'CodingRewind 剪藏'
        result = {}
    elif method == 'thread/unsubscribe':
        result = {'status': 'unsubscribed'}
    elif method == 'thread/read':
        assert params == {'threadId': thread_id, 'includeTurns': True}
        result = thread()
    elif method == 'thread/queue/add':
        state['queueCalls'] += 1
        state['prompt'] = params['input'][0]['text']
        state['clientId'] = params['clientUserMessageId']
        state['submission'] = {'id': 'queue-entry', 'input': params['input'], 'clientUserMessageId': params['clientUserMessageId']}
        state_path.write_text(json.dumps(state))
        if mode == 'disconnect-after-queue':
            sys.exit(0)
        result = {'queuedSubmission': state['submission']}
    elif method == 'thread/queue/list':
        result = {'data': [state['submission']], 'nextCursor': None}
    else:
        raise AssertionError(method)
    response = {'id': message['id'], 'result': result}
    print(json.dumps({'method': 'fixture/notification', 'params': {}}), flush=True)
    print(json.dumps({'id': message['id'] + 100, 'result': {'unrelated': True}}), flush=True)
    data = json.dumps(response, ensure_ascii=False).encode() + b'\n'
    split = len(data) // 2
    sys.stdout.buffer.write(data[:split])
    sys.stdout.buffer.flush()
    time.sleep(0.002)
    sys.stdout.buffer.write(data[split:])
    sys.stdout.buffer.flush()
