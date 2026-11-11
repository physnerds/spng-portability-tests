"""CPU-only tests for the HTCondor campaign wrapper and analysis."""

import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import condor_campaign as condor


UUIDS = [f'GPU-{prefix}'+'0'*24 for prefix in
         ('11111111', '22222222', '33333333', '44444444')]


class CondorCampaignTests(unittest.TestCase):
    def test_resolve_short_uuid_full_uuid_and_index(self):
        devices = [dict(index=str(index), uuid=uuid)
                   for index, uuid in enumerate(UUIDS)]
        short = UUIDS[1][:12]
        resolved = condor.resolve_gpu_tokens([short, UUIDS[2], '3'], devices)
        self.assertEqual([item['uuid'] for item in resolved], UUIDS[1:])

    def test_resolve_rejects_unknown_and_duplicate_tokens(self):
        devices = [dict(index='0', uuid=UUIDS[0]), dict(index='1', uuid=UUIDS[1])]
        with self.assertRaisesRegex(ValueError, 'matched'):
            condor.resolve_gpu_tokens(['GPU-deadbeef'], devices)
        with self.assertRaisesRegex(ValueError, 'not unique'):
            condor.resolve_gpu_tokens(['0', UUIDS[0]], devices)

    def test_analysis_writes_all_metric_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            campaign = output/'campaign'
            campaign.mkdir()
            config = dict(
                cases=[dict(name='n1-p1-t1', processes=1, gpus=1,
                            cores_per_process=4, threads=1)],
                repeats=2, warmups=1, dataset=dict(repeated_copies=False))
            (campaign/'campaign.json').write_text(json.dumps(config))
            rounds = []
            samples = []
            for number in (1, 2):
                label = f'measure{number}'
                start = 100.0+number*10
                rounds.append(dict(
                    case='n1-p1-t1', round=label, warmup=False,
                    processes=1, physical_cores=4, workflow_wall_seconds=1.0,
                    step_wall_seconds=1.4, assembly_seconds=.2,
                    finalized_wall_seconds=1.6, events_per_min=60.0+number,
                    end_to_end_events_per_min=37.0+number))
                rank = campaign/'rounds/n1-p1-t1'/label/'rank0'
                rank.mkdir(parents=True)
                result = dict(validated=True, metadata=dict(gpu_uuid=UUIDS[0]),
                              processes=[dict(slot=0, start_epoch=start,
                                  end_epoch=start+1, elapsed_seconds=1.0,
                                  cpu_seconds=1.0, max_rss_kib=1048576)])
                (rank/'result.json').write_text(json.dumps(result))
                for offset, utilization in ((.1, 10.0), (.5, 20.0), (.9, 30.0)):
                    samples.append(dict(epoch=start+offset, query_seconds=.01,
                        uuid=UUIDS[0], utilization_pct=utilization,
                        memory_mib=1000.0, power_w=100.0))
            (campaign/'rounds.json').write_text(json.dumps(rounds))

            condor.analyze(campaign, samples, output, 500, 'one-gpu-packing')

            for name in ('gpu-process-windows.csv', 'case-metrics.csv',
                         'telemetry-coverage.json', 'telemetry-summary.md'):
                self.assertTrue((output/name).is_file(), name)
            with (output/'case-metrics.csv').open() as stream:
                metrics = list(csv.DictReader(stream))
            self.assertEqual(len(metrics), 1)
            self.assertEqual(metrics[0]['scaling_efficiency_pct'], '')
            summary = (output/'telemetry-summary.md').read_text()
            self.assertIn('one-gpu-packing', summary)
            self.assertIn('Scaling efficiency is intentionally N/A', summary)

    def test_submit_files_keep_uuid_assignment_and_shared_storage_model(self):
        root = Path(__file__).resolve().parents[1]
        for name, gpus in (('pdhd-functional.sub', 1),
                           ('pdhd-scaling.sub', 1),
                           ('pdhd-scaling-4gpu.sub', 4)):
            text = (root/name).read_text()
            self.assertIn(f'request_gpus = {gpus}', text)
            self.assertIn('should_transfer_files = NO', text)
            self.assertNotIn('CUDA_VISIBLE_DEVICES=', text)
            self.assertIn('pdhd-condor.sh', text)


if __name__ == '__main__':
    unittest.main()
