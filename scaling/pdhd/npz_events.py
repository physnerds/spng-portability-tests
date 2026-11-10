"""Matched four-APA archive handling; no WireCell imports or source-tree paths."""
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

KEY = re.compile(r'(frame|channels|tickinfo)_(.*)_(\d+)\.npy')


def digest(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def index(path):
    groups = {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError(f'Duplicate keys: {path}')
        for name in names:
            match = KEY.fullmatch(name)
            if match:
                kind, tag, event = match.groups()
                key = (kind, tag)
                entries = groups.setdefault(int(event), {})
                if key in entries:
                    raise ValueError(f'Ambiguous numeric event ID: {path}:{name}')
                entries[key] = name
    if not groups:
        raise ValueError(f'No frame arrays: {path}; deposit archives are not ADC inputs')
    for event, entries in groups.items():
        tags = {tag for _, tag in entries}
        if any((kind, tag) not in entries for tag in tags
               for kind in ('frame', 'channels', 'tickinfo')):
            raise ValueError(f'Incomplete triplet: {path}, event {event}')
    return groups


def subset(source, target, mapping):
    """mapping is an iterable of (new ID, source ID); payloads remain unchanged."""
    groups = index(source)
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(target, 'x', zipfile.ZIP_STORED) as dst:
        for new, old in mapping:
            for (kind, tag), name in sorted(groups[old].items()):
                dst.writestr(f'{kind}_{tag}_{new}.npy', src.read(name))


def validate(path, expected):
    import numpy as np
    groups = index(path)
    if set(groups) != set(expected):
        raise ValueError(f'Unexpected event IDs in {path}: {sorted(groups)}')
    with zipfile.ZipFile(path) as archive:
        for event, entries in groups.items():
            for kind, tag in entries:
                if kind != 'frame':
                    continue
                def load(k):
                    return np.load(io.BytesIO(archive.read(entries[k, tag])), allow_pickle=False)
                frame, channels, ticks = load('frame'), load('channels'), load('tickinfo')
                if frame.ndim != 2 or not frame.size or not np.isfinite(frame).all():
                    raise ValueError(f'Invalid frame: {path}, {event}, {tag}')
                if (channels.ndim != 1 or len(channels) != frame.shape[0]
                        or not np.issubdtype(channels.dtype, np.integer)
                        or len(np.unique(channels)) != len(channels)):
                    raise ValueError(f'Invalid channels: {path}, {event}, {tag}')
                if ticks.size != 3 or not np.isfinite(ticks).all() or ticks.reshape(-1)[1] <= 0:
                    raise ValueError(f'Invalid tick metadata: {path}, {event}, {tag}')
    return groups


def generate(args):
    sources = [p.resolve(strict=True) for p in args.adc]
    if len(set(sources)) != 4:
        raise ValueError('Supply four distinct APA-specific archives in APA 0–3 order')
    groups = [index(p) for p in sources]
    ids = sorted(groups[0])
    if any(set(g) != set(ids) for g in groups[1:]):
        raise ValueError('APA event-ID sets must agree exactly')
    if len(ids) < args.events and not args.repeat:
        raise ValueError(f'Only {len(ids)} source events; use --repeat explicitly for copies')
    selected = [ids[i % len(ids)] for i in range(args.events)]
    mapping = list(enumerate(selected, start=1))
    args.output.mkdir(parents=True, exist_ok=False)
    for apa, source in enumerate(sources):
        target = args.output / f'adc-tpc{apa}.npz'
        subset(source, target.with_suffix('.partial'), mapping)
        validate(target.with_suffix('.partial'), range(1, args.events + 1))
        target.with_suffix('.partial').rename(target)
    meta = dict(schema=1, events=args.events, apas=4,
                repeated_copies=len(set(selected)) != len(selected),
                mapping=[dict(event_id=new, source_event_id=old) for new, old in mapping],
                sources=[dict(path=str(p), sha256=digest(p)) for p in sources],
                archives=[dict(path=f'adc-tpc{a}.npz', sha256=digest(args.output/f'adc-tpc{a}.npz'))
                          for a in range(4)],
                note='Matched ADC selection/repetition, not fresh physics simulation. '
                     'Physical correspondence and APA identity rely on the supplied sources.')
    (args.output/'dataset.json').write_text(json.dumps(meta, indent=2)+'\n')
