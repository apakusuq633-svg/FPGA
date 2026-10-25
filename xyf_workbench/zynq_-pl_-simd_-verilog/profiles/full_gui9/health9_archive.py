"""Optional PC SQLite archive/proxy for the nine-microphone PS monitor.
No third-party packages. Board uptime and PC receive UTC remain distinct.
"""
import argparse
import json
import secrets
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Store:
    def __init__(self, path):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS sessions(sid TEXT PRIMARY KEY,seen REAL,rc INTEGER DEFAULT 0,ec INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS records(sid TEXT,cursor INTEGER,received REAL,body TEXT,PRIMARY KEY(sid,cursor));
        CREATE TABLE IF NOT EXISTS events(sid TEXT,id INTEGER,revision INTEGER,received REAL,body TEXT,PRIMARY KEY(sid,id));
        ''')

    def cursors(self, sid):
        with self.lock:
            row = self.db.execute('SELECT rc,ec FROM sessions WHERE sid=?', (sid,)).fetchone()
            return row or (0, 0)

    def ingest(self, status, history, events):
        sid = status['session']
        if not sid or sid == '0' or history['session'] != sid or events['session'] != sid:
            raise ValueError('Unbound or changed board session')
        now = time.time()
        with self.lock, self.db:
            self.db.execute('INSERT INTO sessions(sid,seen) VALUES(?,?) ON CONFLICT(sid) DO UPDATE SET seen=excluded.seen', (sid, now))
            for row in history['records']:
                self.db.execute('INSERT OR IGNORE INTO records VALUES(?,?,?,?)', (sid, row['cursor'], now, json.dumps(row)))
            for row in events['events']:
                self.db.execute('INSERT INTO events VALUES(?,?,?,?,?) ON CONFLICT(sid,id) DO UPDATE SET revision=excluded.revision,received=excluded.received,body=excluded.body WHERE excluded.revision>events.revision',
                                (sid, row['id'], row['revision'], now, json.dumps(row)))
            self.db.execute('UPDATE sessions SET rc=MAX(rc,?),ec=MAX(ec,?) WHERE sid=?', (history['next_after'], events['next_after'], sid))
            # Bounded retention, including after restart. Never invent recovery.
            self.db.execute('DELETE FROM records WHERE rowid IN (SELECT rowid FROM records ORDER BY received DESC LIMIT -1 OFFSET 100000)')
            self.db.execute('DELETE FROM events WHERE rowid IN (SELECT rowid FROM events ORDER BY received DESC LIMIT -1 OFFSET 5000)')
            self.db.execute('DELETE FROM sessions WHERE rowid IN (SELECT rowid FROM sessions ORDER BY seen DESC LIMIT -1 OFFSET 128)')

    def query(self, seconds=300, limit=256):
        seconds = min(max(int(seconds), 1), 86400)
        limit = min(max(int(limit), 1), 1000)
        with self.lock:
            rows = self.db.execute('SELECT sid,received,body FROM records WHERE received>=? ORDER BY received,cursor LIMIT 100000', (time.time()-seconds,)).fetchall()
            total = len(rows)
            if total > limit:
                rows = [rows[i*(total-1)//(limit-1)] for i in range(limit)] if limit > 1 else rows[-1:]
            events = self.db.execute('SELECT sid,received,body FROM events ORDER BY received DESC LIMIT 64').fetchall()
        def decode(values):
            return [dict(json.loads(body), archive_session=sid, received_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(stamp)), plot_ms=int(stamp*1000)) for sid, stamp, body in values]
        return dict(records=decode(rows), events=decode(events), matching_records=total, returned_records=len(rows), time_basis='PC receive UTC; board ms retained separately')


class Collector:
    def __init__(self, board, store):
        self.board, self.store = board.rstrip('/'), store
        self.error, self.last_ok = 'Waiting for first poll', 0
        self.stop = threading.Event()

    def get(self, path):
        with urllib.request.urlopen(self.board+path, timeout=2) as r:
            return json.load(r)

    def poll(self):
        s = self.get('/api/health9/status')
        if s['session'] == '0':
            self.get('/api/health9/session/'+str(secrets.randbelow(4503599627370494)+1))
            s = self.get('/api/health9/status')
        rc, ec = self.store.cursors(s['session'])
        h = self.get('/api/health9/history?after='+str(rc)+'&limit=32')
        e = self.get('/api/health9/events?after='+str(ec)+'&limit=16')
        self.store.ingest(s, h, e)
        self.error, self.last_ok = '', time.time()

    def run(self):
        while not self.stop.is_set():
            try:
                self.poll()
            except Exception as exc:
                self.error = str(exc)  # Storage/network failure never touches PS.
            self.stop.wait(1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--board', default='http://192.168.2.10')
    p.add_argument('--db', type=Path, default=Path.home()/'acoustic_health9'/'health.sqlite3')
    p.add_argument('--port', type=int, default=8769)
    a = p.parse_args()
    a.db.parent.mkdir(parents=True, exist_ok=True)
    store, board = Store(a.db), a.board.rstrip('/')
    collector = Collector(board, store)
    threading.Thread(target=collector.run, daemon=True).start()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                u = urllib.parse.urlsplit(self.path)
                if u.path == '/archive/history':
                    q = urllib.parse.parse_qs(u.query)
                    result = store.query(q.get('seconds', ['300'])[0])
                    result.update(archive_error=collector.error, last_ok=collector.last_ok)
                    data, content_type, code = json.dumps(result).encode(), 'application/json', 200
                elif u.path == '/archive/status':
                    data = json.dumps(dict(error=collector.error, last_ok=collector.last_ok, db=str(a.db))).encode()
                    content_type, code = 'application/json', 200
                elif u.path == '/' or u.path.startswith('/api/'):
                    # Same-origin proxy: fixed board address; no arbitrary URL forwarding.
                    with urllib.request.urlopen(board+self.path, timeout=3) as r:
                        data, content_type, code = r.read(), r.headers.get('Content-Type', 'application/octet-stream'), r.status
                else:
                    data, content_type, code = b'Not found', 'text/plain', 404
            except urllib.error.HTTPError as exc:
                data, content_type, code = exc.read(), 'application/json', exc.code
            except Exception as exc:
                data, content_type, code = json.dumps(dict(error=str(exc))).encode(), 'application/json', 503
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)

    print(f'Open http://127.0.0.1:{a.port}/ ; SQLite: {a.db}', flush=True)
    try:
        ThreadingHTTPServer(('127.0.0.1', a.port), Handler).serve_forever()
    except KeyboardInterrupt:
        collector.stop.set()


if __name__ == '__main__':
    main()
