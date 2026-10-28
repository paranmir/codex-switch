"""Probe an installed Codex binary using only fake accounts in an isolated home.

No prompts, login/logout, real credentials, or model requests are sent.
Run: python tests/auth-cache-probe.py --codex C:\\path\\to\\codex.exe
"""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


def fake_auth(account):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    now = int(time.time())
    payload = {'sub': account, 'email': account + '@example.test', 'exp': now + 86400,
               'https://api.openai.com/auth': {'chatgpt_account_id': account,
                                             'chatgpt_plan_type': 'plus'}}
    token = encode({'alg': 'none'}) + '.' + encode(payload) + '.fake'
    return {'auth_mode': 'chatgpt', 'OPENAI_API_KEY': None,
            'tokens': {'id_token': token, 'access_token': token,
                       'refresh_token': 'fake-not-valid', 'account_id': account},
            'last_refresh': datetime.datetime.now(datetime.timezone.utc).isoformat()}


class Server:
    def __init__(self, executable, directory):
        env = {k: v for k, v in os.environ.items()
               if not k.upper().startswith(('CODEX_', 'OPENAI_'))}
        env.update(CODEX_HOME=str(directory), HTTP_PROXY='http://127.0.0.1:9',
                   HTTPS_PROXY='http://127.0.0.1:9', ALL_PROXY='http://127.0.0.1:9',
                   NO_PROXY='')
        self.process = subprocess.Popen(
            [executable, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding='utf-8', env=env,
            cwd=directory, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        self.lines = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        try:
            self.call('initialize', {'clientInfo': {'name': 'codex_switch_probe', 'version': '1.0'}})
            self.process.stdin.write('{"method":"initialized","params":{}}\n')
            self.process.stdin.flush()
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def call(self, method, params):
        self.next_id += 1
        self.process.stdin.write(json.dumps({'id': self.next_id, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Probe RPC timed out: ' + method)
            line = self.lines.get(timeout=remaining)
            if line is None:
                raise RuntimeError('Probe server exited')
            message = json.loads(line)
            if message.get('id') == self.next_id:
                if 'error' in message:
                    raise RuntimeError('Probe RPC failed: ' + method)
                return message.get('result', {})

    def close(self):
        try:
            self.process.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()  # Only this probe's own isolated child.
            self.process.wait(timeout=5)
        self.process.stdout.close()


def run(executable):
    with tempfile.TemporaryDirectory(prefix='codex-auth-cache-probe-') as folder:
        directory = Path(folder)
        (directory / 'config.toml').write_text('cli_auth_credentials_store = "file"\n', encoding='utf-8')
        auth_path = directory / 'auth.json'
        auth_path.write_text(json.dumps(fake_auth('fixture-a')), encoding='utf-8')
        server = None
        try:
            server = Server(executable, directory)
            before = server.call('account/read', {'refreshToken': False})
            replacement = directory / 'auth.replacement'
            replacement.write_text(json.dumps(fake_auth('fixture-b')), encoding='utf-8')
            replacement.replace(auth_path)
            after = server.call('account/read', {'refreshToken': False})
            refreshed = server.call('account/read', {'refreshToken': True})
        finally:
            if server:
                server.close()
        server = None
        try:
            server = Server(executable, directory)
            restarted = server.call('account/read', {'refreshToken': False})
        finally:
            if server:
                server.close()
        email = lambda response: (response.get('account') or {}).get('email')
        result = {'before': email(before), 'after_file_change': email(after),
                  'after_refresh_request': email(refreshed), 'after_restart': email(restarted)}
        assert result['before'] == 'fixture-a@example.test', 'Fixture A was not loaded'
        assert result['after_restart'] == 'fixture-b@example.test', 'Restart did not load fixture B'
        print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex', required=True)
    run(parser.parse_args().codex)
