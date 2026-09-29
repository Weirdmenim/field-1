#!/usr/bin/env python3
import json
import os
import statistics
import time
import urllib.request
from pathlib import Path

SUPABASE = os.environ.get('PHASE11_SUPABASE_URL', 'http://127.0.0.1:54321')
ANON = os.environ.get('SUPABASE_ANON_KEY', os.environ.get('VITE_SUPABASE_ANON_KEY', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'))
EMAIL = os.environ.get('PHASE11_TEST_EMAIL', 'phase10-runtime@example.test')
PASSWORD = os.environ.get('PHASE11_TEST_PASSWORD', 'Phase10!Runtime123')
EVIDENCE = Path(os.environ.get('PHASE11_EVIDENCE_DIR', '.phase11-evidence')) / 'performance'
EVIDENCE.mkdir(parents=True, exist_ok=True)


def request_json(url, method='GET', body=None, token=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {'apikey': ANON, 'Content-Type': 'application/json'}
    if token: headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode() or 'null')


def p95(values):
    s = sorted(values)
    return s[max(0, min(len(s)-1, int((len(s)-1)*0.95)))]


auth = request_json(f'{SUPABASE}/auth/v1/token?grant_type=password', 'POST', {'email': EMAIL, 'password': PASSWORD})
token = auth['access_token']
scenarios = {}

for name, url, method, body in [
    ('inventory_balance_read', f'{SUPABASE}/rest/v1/inventory_balances?location_id=eq.33333333-3333-3333-3333-333333333331&select=product_id,on_hand_base_qty,reserved_base_qty&limit=50', 'GET', None),
    ('identifier_resolution', f'{SUPABASE}/rest/v1/rpc/resolve_inventory_identifier', 'POST', {'p_location_id':'33333333-3333-3333-3333-333333333331','p_code':'MIRO-LAP-14','p_context':'browse','p_document_id':None}),
]:
    samples = []
    for _ in range(20):
        start = time.perf_counter()
        request_json(url, method, body, token)
        samples.append((time.perf_counter() - start) * 1000)
    scenarios[name] = {
        'samples': len(samples),
        'avg_ms': statistics.mean(samples),
        'p95_ms': p95(samples),
        'max_ms': max(samples),
    }

stress_path = Path(os.environ.get('PHASE11_EVIDENCE_DIR', '.phase11-evidence')) / 'offline-stress' / 'results.json'
if stress_path.exists():
    stress = json.loads(stress_path.read_text())
    if stress.get('status') == 'PASS':
        scenarios['offline_sync'] = {
            'commands': stress.get('commands_confirmed'),
            'throughput_ops_sec': stress.get('throughput_ops_sec'),
            'elapsed_seconds': stress.get('elapsed_seconds'),
        }

result = {'status': 'PASS', 'baseline_only_no_sla_claim': True, 'scenarios': scenarios}
(EVIDENCE / 'benchmark.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps(result, indent=2))
