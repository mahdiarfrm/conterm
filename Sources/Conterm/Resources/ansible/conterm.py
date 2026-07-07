# Conterm notification callback: mirrors playbook events to the JSONL
# feed the app tails (one object per line). Runs IN ADDITION to the
# stdout callback — console output is untouched. Inert unless
# CONTERM_ANSIBLE_LOG is set (the shell hook sets it per pane), and any
# write failure disables the mirror rather than the run.
from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

import json
import os
import time

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = '''
    name: conterm
    type: notification
    short_description: mirror run events to Conterm's live cockpit
    description:
        - Writes one JSON object per event to $CONTERM_ANSIBLE_LOG.
'''


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'notification'
    CALLBACK_NAME = 'conterm'

    def __init__(self):
        super(CallbackModule, self).__init__()
        self._path = os.environ.get('CONTERM_ANSIBLE_LOG')

    def _emit(self, obj):
        if not self._path:
            return
        obj['ts'] = time.time()
        try:
            with open(self._path, 'a') as f:
                f.write(json.dumps(obj) + '\n')
        except Exception:
            self._path = None

    def v2_playbook_on_start(self, playbook):
        name = getattr(playbook, '_file_name', '') or ''
        self._emit({'e': 'playbook', 'name': os.path.basename(name)})

    def v2_playbook_on_play_start(self, play):
        self._emit({'e': 'play', 'name': play.get_name().strip()})

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._emit({'e': 'task', 'name': task.get_name().strip()})

    def _host_event(self, kind, result, msg=None, extra=None):
        obj = {'e': kind,
               'host': result._host.get_name(),
               'task': result._task.get_name().strip()}
        if msg:
            obj['msg'] = str(msg)[:400]
        if extra:
            obj.update(extra)
        self._emit(obj)

    def v2_runner_on_ok(self, result):
        self._host_event('ok', result,
                         extra={'changed': bool(result._result.get('changed'))})

    def v2_runner_on_failed(self, result, ignore_errors=False):
        self._host_event('failed', result,
                         msg=result._result.get('msg', ''),
                         extra={'ignored': bool(ignore_errors)})

    def v2_runner_on_unreachable(self, result):
        self._host_event('unreachable', result,
                         msg=result._result.get('msg', ''))

    def v2_runner_on_skipped(self, result):
        self._host_event('skipped', result)

    def v2_playbook_on_stats(self, stats):
        hosts = {}
        for h in sorted(stats.processed.keys()):
            s = stats.summarize(h)
            hosts[h] = {'ok': s.get('ok', 0),
                        'changed': s.get('changed', 0),
                        'failed': s.get('failures', 0),
                        'unreachable': s.get('unreachable', 0),
                        'skipped': s.get('skipped', 0)}
        self._emit({'e': 'stats', 'hosts': hosts})
