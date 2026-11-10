"""Container-side preparation and structural checks for the PDHD smoke test."""
import json
from pathlib import Path
import re
import sys
import zipfile

from npz_events import digest, index, validate

root = Path('/work')


def prepare(source, count):
    pattern = re.compile(r'depo_(data|info)_(\d+)\.npy')
    groups = {}
    with zipfile.ZipFile(source) as src:
        names = src.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate deposit archive entries')
        for name in names:
            match = pattern.fullmatch(name)
            if match:
                kind, ident = match.groups()
                entries = groups.setdefault(int(ident), {})
                if kind in entries:
                    raise ValueError('Ambiguous deposit IDs')
                entries[kind] = name
        if not groups or any(set(g) != {'data', 'info'} for g in groups.values()):
            raise ValueError('Expected matched depo_data/depo_info pairs, not ADC frames')
        selected = sorted(groups)[:count]
        if len(selected) != count:
            raise ValueError(f'Requested {count} deposit sets; only {len(groups)} available')
        # Preserve event IDs and payloads; never manufacture or repeat deposits.
        with zipfile.ZipFile(root/'depos.npz', 'x') as dst:
            for ident in selected:
                for name in groups[ident].values():
                    dst.writestr(name, src.read(name))
    record = dict(source_sha256=digest(source), selected_deposit_ids=selected,
                  events=count, prepared_sha256=digest(root/'depos.npz'),
                  note='Existing deposit sets; distinct IDs do not imply distinct physics samples.')
    (root/'input.json').write_text(json.dumps(record, indent=2)+'\n')


def check():
    request = json.loads((root/'input.json').read_text())
    paths = [root/f'adc-tpc{apa}.npz' for apa in range(4)]
    ids = sorted(index(paths[0]))
    if len(ids) != request['events']:
        raise ValueError(f'Expected {request["events"]} frames per APA, got {ids}')
    archives = []
    for apa, path in enumerate(paths):
        validate(path, ids)
        archives.append(dict(apa=apa, path=path.name, sha256=digest(path)))
    record = dict(status='PASS', complete_events=len(ids), event_ids=ids,
                  selected_deposit_ids=request['selected_deposit_ids'], archives=archives,
                  note='Structural smoke test only; no numerical or geometry equivalence established.')
    (root/'validation.json').write_text(json.dumps(record, indent=2)+'\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    if sys.argv[1] == 'prepare':
        prepare(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1] == 'validate':
        check()
    else:
        raise SystemExit('Expected prepare or validate')
