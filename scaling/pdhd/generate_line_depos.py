#!/usr/bin/env python3
"""Run spng-ssss line_depo targets and merge their deposit archives."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


THETA_XZ_DEG = (0, 1, 3, 5, 10, 20, 30, 45, 60, 75, 80, 82, 84, 89)
THETA_Y_DEG = (90,)*len(THETA_XZ_DEG)
CONFIGURATIONS = [(plane, theta_xz, theta_y)
                  for plane in (0, 1, 2)
                  for theta_xz, theta_y in zip(THETA_XZ_DEG, THETA_Y_DEG)]
PATTERN = re.compile(r'depo_(data|info)_(\d+)\.npy')


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            value.update(block)
    return value.hexdigest()


def entries(path):
    found = {}
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            match = PATTERN.fullmatch(name)
            if not match:
                continue
            kind, event = match.groups()
            found.setdefault(int(event), {})[kind] = name
    if len(found) != 1 or any(set(value) != {'data', 'info'} for value in found.values()):
        raise RuntimeError(f'Expected one complete deposit event in {path}, got {found}')
    return next(iter(found.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--events', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--metadata', type=Path, required=True)
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--snakefile', type=Path, required=True)
    args = parser.parse_args()
    if args.events < 1 or args.events > len(CONFIGURATIONS):
        parser.error(f'--events must be in [1, {len(CONFIGURATIONS)}]')
    if args.output.exists() or args.metadata.exists() or args.workdir.exists():
        parser.error('output, metadata, and workdir must be fresh')
    if not args.snakefile.is_file():
        parser.error(f'Snakefile does not exist: {args.snakefile}')
    args.workdir.mkdir(parents=True)

    records = []
    targets = []
    for event, (plane, theta_xz, theta_y) in enumerate(CONFIGURATIONS[:args.events]):
        relative = Path('pdhd/line/depo')/f'p{plane}-txz{theta_xz}-ty{theta_y}'/'1'
        depos = args.workdir/relative/'data.npz'
        meta = args.workdir/relative/'meta.json'
        targets.append(str(relative/'data.npz'))
        records.append(dict(event_id=event, plane=plane, theta_xz_deg=theta_xz,
                            theta_y_deg=theta_y, offset='+1*m,0*m,0*m',
                            detector='pdhd', angle_coords='wire-plane',
                            target=str(relative/'data.npz'), depos=str(depos),
                            source_meta=str(meta)))

    command = ['snakemake', '--snakefile', str(args.snakefile.resolve()),
               '--cores', '1', '--printshellcmds', *targets]
    log = args.workdir/'snakemake.log'
    with log.open('w') as stream:
        result = subprocess.run(command, cwd=args.workdir, stdout=stream,
                                stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Snakemake line_depo failed ({result.returncode}); see {log}')

    generated = []
    for record in records:
        depos = Path(record['depos'])
        meta = Path(record['source_meta'])
        if not meta.is_file():
            raise RuntimeError(f'line_depo did not create metadata: {meta}')
        mapping = entries(depos)
        generated.append((depos, mapping))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'x', zipfile.ZIP_STORED) as target:
        for event, (source_path, mapping) in enumerate(generated):
            with zipfile.ZipFile(source_path) as source:
                for kind in ('data', 'info'):
                    target.writestr(f'depo_{kind}_{event}.npy', source.read(mapping[kind]))
    args.metadata.write_text(json.dumps(dict(
        schema=1, generator='spng/test/spng-ssss:line_depo', events=args.events,
        snakefile=str(args.snakefile), snakefile_sha256=digest(args.snakefile),
        command=command, log=str(log),
        configurations=records,
        note='Deterministic line deposits; event IDs do not imply independent physics.'),
        indent=2)+'\n')
    print(f'Generated {args.events} line-deposit events in {args.output}')


if __name__ == '__main__':
    main()
