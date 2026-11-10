#!/usr/bin/env python3
"""Cancel a fresh real campaign after release; retain a machine-readable report."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--campaign', type=Path, required=True)
p.add_argument('--report', type=Path, required=True)
a = p.parse_args()
root = a.campaign.resolve()
with a.report.with_suffix('.log').open('w') as log:
    process = subprocess.Popen([sys.executable, str(root/'suite/pdhd.py'), 'run',
                                '--campaign', str(root)], stdout=log, stderr=subprocess.STDOUT)
    cids = []
    released = False
    try:
        deadline = time.monotonic()+180
        while time.monotonic() < deadline:
            for path in root.glob('rounds/*/*/rank*/container.cid'):
                cid = path.read_text().strip()
                if cid and cid not in cids:
                    cids.append(cid)
            if list(root.glob('rounds/*/*/release.json')):
                released = True
                break
            if process.poll() is not None:
                raise RuntimeError('Campaign exited before barrier release')
            time.sleep(.05)
        if not released:
            raise TimeoutError('No release marker')
        time.sleep(1)
        if list(root.glob('rounds/*/*/rank*/wc-finished.json')):
            raise RuntimeError('Work finished before cancellation; test inconclusive')
        process.send_signal(signal.SIGTERM)
        rc = process.wait(timeout=90)
        leftovers = []
        # List containers rather than image inspect: works with migrated RO images.
        listing = subprocess.run(['podman-hpc', 'ps', '-a', '--format', 'json'],
                                 capture_output=True, text=True, check=True, timeout=30)
        for container in json.loads(listing.stdout or '[]'):
            ident = container.get('Id', container.get('ID', ''))
            if any(ident.startswith(cid) or cid.startswith(ident) for cid in cids) and ident:
                leftovers.append(container)
        report = dict(returncode=rc, after_release=released, container_ids=cids,
                      leftover_containers=leftovers, lock_removed=not (root/'.running').exists(),
                      failed_records=[str(x) for x in root.glob('rounds/*/*/failed.json')])
        report['passed'] = rc != 0 and not leftovers and report['lock_removed'] and bool(report['failed_records']) and bool(cids)
        a.report.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        if not report['passed']:
            raise SystemExit(1)
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=90)
