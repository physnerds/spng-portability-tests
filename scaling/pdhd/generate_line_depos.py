#!/usr/bin/env python3
"""Generate configurable line deposits with direct wcpy Bash commands."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import zipfile


HERE = Path(__file__).resolve().parent
DEFAULT_TEMPLATE = HERE/'line-depo-template.sh.in'
DEFAULT_PLANES = '0,1,2'
DEFAULT_THETA_XZ_DEG = '0,1,3,5,10,20,30,45,60,75,80,82,84,89'
DEFAULT_THETA_Y_DEG = '90'
PATTERN = re.compile(r'depo_(data|info)_(\d+)\.npy')


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            value.update(block)
    return value.hexdigest()


def csv_values(value, convert, label):
    fields = [field.strip() for field in value.split(',')]
    if not fields or any(not field for field in fields):
        raise argparse.ArgumentTypeError(f'{label} must be a nonempty comma-separated list')
    try:
        return [convert(field) for field in fields]
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f'invalid {label}: {value!r}') from exc


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return number


def number_text(value):
    return f'{value:g}'


def configurations(planes, theta_xz, theta_y):
    if len(theta_y) == 1:
        theta_y = theta_y*len(theta_xz)
    if len(theta_y) != len(theta_xz):
        raise ValueError('--theta-y-deg must contain one value or match --theta-xz-deg')
    return [(plane, xz, y) for plane in planes for xz, y in zip(theta_xz, theta_y)]


def entries(path):
    found = {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError(f'Duplicate archive entries in {path}')
        for name in names:
            match = PATTERN.fullmatch(name)
            if not match:
                continue
            kind, event = match.groups()
            found.setdefault(int(event), {})[kind] = name
    if len(found) != 1 or any(set(value) != {'data', 'info'} for value in found.values()):
        raise RuntimeError(f'Expected one complete deposit event in {path}, got {found}')
    return next(iter(found.values()))


def executable(value, parser, label):
    path = shutil.which(value)
    if path is None:
        parser.error(f'{label} executable not found on PATH: {value}')
    return path


def render(template, values, parser):
    try:
        return template.format_map(values)
    except KeyError as exc:
        parser.error(f'unknown or unavailable template placeholder: {exc.args[0]}')
    except (IndexError, ValueError) as exc:
        parser.error(f'invalid Bash template: {exc}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--events', type=positive,
                        help='number of configurations to generate; default is the full grid')
    parser.add_argument('--output', type=Path, required=True,
                        help='merged output deposit NPZ')
    parser.add_argument('--metadata', type=Path, required=True,
                        help='JSON provenance for the generated grid')
    parser.add_argument('--workdir', type=Path, required=True,
                        help='fresh directory for scripts, logs, and one-event outputs')
    parser.add_argument('--template', type=Path, default=DEFAULT_TEMPLATE,
                        help='Bash template containing the documented placeholders')
    parser.add_argument('--wcpy', default='wcpy', help='wcpy executable name or path')
    parser.add_argument('--bash', default='bash', help='Bash executable name or path')
    parser.add_argument('--detector', default='pdhd')
    parser.add_argument('--offset', default='+1*m,0*m,0*m')
    parser.add_argument('--angle-coords', default='wire-plane')
    parser.add_argument('--planes', default=DEFAULT_PLANES,
                        help='comma-separated plane numbers')
    parser.add_argument('--theta-xz-deg', default=DEFAULT_THETA_XZ_DEG,
                        help='comma-separated XZ angles in degrees')
    parser.add_argument('--theta-y-deg', default=DEFAULT_THETA_Y_DEG,
                        help='one Y angle or a comma-separated list matching XZ angles')
    args = parser.parse_args()

    try:
        planes = csv_values(args.planes, int, 'planes')
        theta_xz = csv_values(args.theta_xz_deg, float, 'theta-xz-deg')
        theta_y = csv_values(args.theta_y_deg, float, 'theta-y-deg')
        planned = configurations(planes, theta_xz, theta_y)
    except (argparse.ArgumentTypeError, ValueError) as exc:
        parser.error(str(exc))
    if len(set(planes)) != len(planes):
        parser.error('--planes contains duplicates')
    if not all(math.isfinite(value) for value in theta_xz+theta_y):
        parser.error('angles must be finite numbers')
    expanded_y = theta_y if len(theta_y) > 1 else theta_y*len(theta_xz)
    if len(set(zip(theta_xz, expanded_y))) != len(theta_xz):
        parser.error('the angle grid contains duplicate theta-xz/theta-y pairs')
    if args.events is not None:
        if args.events > len(planned):
            parser.error(f'--events={args.events} exceeds the {len(planned)} configurations')
        planned = planned[:args.events]
    if args.output.exists() or args.metadata.exists() or args.workdir.exists():
        parser.error('output, metadata, and workdir must be fresh')
    if not args.template.is_file():
        parser.error(f'Bash template does not exist: {args.template}')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', args.detector):
        parser.error('--detector must be a safe single path component')
    args.output = args.output.resolve()
    args.metadata = args.metadata.resolve()
    args.workdir = args.workdir.resolve()
    args.template = args.template.resolve(strict=True)
    wcpy = executable(args.wcpy, parser, 'wcpy')
    bash = executable(args.bash, parser, 'Bash')
    template = args.template.read_text()
    args.workdir.mkdir(parents=True)

    records = []
    generated = []
    for event, (plane, theta_xz_deg, theta_y_deg) in enumerate(planned):
        xz_text = number_text(theta_xz_deg)
        y_text = number_text(theta_y_deg)
        relative = Path(args.detector)/'line'/'depo'/f'p{plane}-txz{xz_text}-ty{y_text}'/'1'
        directory = args.workdir/relative
        directory.mkdir(parents=True)
        depos = directory/'data.npz'
        meta = directory/'meta.json'
        script = directory/'generate.sh'
        log = directory/'wcpy.log'
        values = {
            'wcpy': shlex.quote(wcpy),
            'offset': shlex.quote(args.offset),
            'detector': shlex.quote(args.detector),
            'plane': shlex.quote(str(plane)),
            'angle_coords': shlex.quote(args.angle_coords),
            'theta_xz': shlex.quote(f'{xz_text}*deg'),
            'theta_y': shlex.quote(f'{y_text}*deg'),
            'output_depos': shlex.quote(str(depos)),
            'output_meta': shlex.quote(str(meta)),
        }
        script.write_text(render(template, values, parser))
        script.chmod(0o755)
        with log.open('w') as stream:
            result = subprocess.run([bash, str(script)], cwd=directory,
                                    stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'wcpy failed ({result.returncode}); see {log}')
        if not meta.is_file():
            raise RuntimeError(f'wcpy did not create metadata: {meta}')
        mapping = entries(depos)
        generated.append((depos, mapping))
        records.append(dict(event_id=event, plane=plane,
                            theta_xz_deg=theta_xz_deg, theta_y_deg=theta_y_deg,
                            offset=args.offset, detector=args.detector,
                            angle_coords=args.angle_coords,
                            depos=str(depos), source_meta=str(meta),
                            script=str(script), log=str(log)))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'x', zipfile.ZIP_STORED) as target:
        for event, (source_path, mapping) in enumerate(generated):
            with zipfile.ZipFile(source_path) as source:
                for kind in ('data', 'info'):
                    target.writestr(f'depo_{kind}_{event}.npy', source.read(mapping[kind]))
    args.metadata.write_text(json.dumps(dict(
        schema=2, generator='wcpy gen detlinegen', events=len(records),
        template=str(args.template), template_sha256=digest(args.template),
        wcpy=wcpy, bash=bash,
        parameters=dict(detector=args.detector, offset=args.offset,
                        angle_coords=args.angle_coords, planes=planes,
                        theta_xz_deg=theta_xz, theta_y_deg=theta_y),
        configurations=records,
        note='Deterministic line deposits; event IDs do not imply independent physics.'),
        indent=2)+'\n')
    print(f'Generated {len(records)} line-deposit events in {args.output}')


if __name__ == '__main__':
    main()
