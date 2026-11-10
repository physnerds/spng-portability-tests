"""CPU-only runner regressions; no Wire-Cell, container, or Slurm required."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pdhd as runner

UUIDS = ['GPU-'+f'{i:032x}' for i in range(1, 20)]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        active, ranks = runner.placement(2, 8, 2)
        self.case = dict(name='fixture', nodes=2, processes=8, ranks=ranks,
                         active_gpus_per_node=active, gpus=len(ranks), cores_per_process=1)
        for rank, assignment in enumerate(ranks):
            host = f'node{assignment["node"]}'
            cpus = assignment['slots']
            topology = {str(cpu): [0, cpu] for cpu in cpus}
            directory = self.root/f'rank{rank}'
            directory.mkdir()
            runner.save(directory/'launch.json', dict(host=host, affinity=cpus,
                        physical_cores=topology, expected_gpu=UUIDS[rank]))
            runner.save(directory/'ready.json', dict(host=host, slots=cpus,
                        cpu_masks={str(cpu): [cpu] for cpu in cpus},
                        physical_cores=topology, gpu_uuid=UUIDS[rank]))

    def tearDown(self):
        self.tmp.cleanup()

    def change(self, rank, name, mutate):
        path = self.root/f'rank{rank}/{name}.json'
        data = runner.read(path)
        mutate(data)
        runner.save(path, data)

    def test_partition_nondivisible_complete_disjoint(self):
        events = list(range(17))
        batches = runner.partitions(events, 4)
        self.assertEqual([len(b) for b in batches], [5, 4, 4, 4])
        self.assertEqual(sorted(sum(batches, [])), events)
        with self.assertRaises(ValueError):
            runner.partitions(events, 18)

    def test_placement_matrix(self):
        for nodes in (1, 2, 4):
            for per_node in (1, 2, 4, 5, 8, 16):
                active, ranks = runner.placement(nodes, nodes*per_node, 4)
                self.assertEqual(active, min(per_node, 4))
                self.assertEqual(sorted(sum([r['slots'] for r in ranks], [])),
                                 list(range(nodes*per_node)))
                self.assertTrue(all(r['slots'] for r in ranks))
        with self.assertRaises(ValueError):
            runner.placement(2, 3, 4)

    def test_planner_rejects_padded_slurm_oversubscription(self):
        archives = []
        for apa in range(4):
            path = self.root/f'adc-tpc{apa}.npz'
            path.write_bytes(b'fixture')
            archives.append(dict(path=path.name, sha256=runner.digest(path)))
        runner.save(self.root/'dataset.json', dict(apas=4, events=5,
                    mapping=[dict(event_id=e) for e in range(5)], archives=archives))
        args = SimpleNamespace(profile='perlmutter', dataset=self.root,
                    gpus_per_node=None, physical_cores_per_node=None,
                    slurm_cpus_per_core=None, runtime=None, container_python=None,
                    network=None, threads=[12], cores_per_process=12,
                    nodes=[1], processes=[5])
        # 5*12=60 useful cores, but four equally sized Slurm controllers
        # each reserve 2*12 cores: 96 requested on a 64-core node.
        with patch.object(runner, 'validate'):
            with self.assertRaisesRegex(ValueError, 'Uniform Slurm'):
                runner.plan(args)

    def test_topology_selects_one_smt_sibling(self):
        with patch.object(runner.os, 'sched_getaffinity', return_value={1, 2, 65, 66}), \
             patch.object(runner, 'cpu_identity', side_effect=lambda c: [0, c % 64]):
            self.assertEqual(runner.physical_cpus(), [1, 2])

    def test_valid_ready_metadata(self):
        self.assertEqual(len(runner.check_ready(self.root, self.case)), 4)

    def test_smt_overlap_across_controllers(self):
        # Distinct logical IDs but the same physical package/core.
        for name in ('launch', 'ready'):
            self.change(1, name, lambda m: m['physical_cores'].update({'1': [0, 0]}))
        with self.assertRaisesRegex(ValueError, 'Physical CPU'):
            runner.check_ready(self.root, self.case)

    def test_container_escape_rejected(self):
        self.change(0, 'launch', lambda m: m.update(affinity=[]))
        with self.assertRaisesRegex(ValueError, 'outside host'):
            runner.check_ready(self.root, self.case)

    def test_wrong_core_count_rejected(self):
        self.change(0, 'ready', lambda m: m['cpu_masks'].update({'0': []}))
        with self.assertRaisesRegex(ValueError, 'core count'):
            runner.check_ready(self.root, self.case)

    def test_wrong_slots_rejected(self):
        self.change(0, 'ready', lambda m: m.update(slots=[99]))
        with self.assertRaisesRegex(ValueError, 'slots'):
            runner.check_ready(self.root, self.case)

    def test_wrong_node_placement_rejected(self):
        self.change(1, 'ready', lambda m: m.update(host='other'))
        with self.assertRaisesRegex(ValueError, 'node split'):
            runner.check_ready(self.root, self.case)

    def test_duplicate_gpu_uuid_alias_rejected(self):
        self.change(1, 'ready', lambda m: m.update(gpu_uuid=UUIDS[0][4:].upper()))
        with self.assertRaisesRegex(ValueError, 'GPU assignments overlap'):
            runner.check_ready(self.root, self.case)

    def test_wrong_gpu_mapping_rejected(self):
        self.change(0, 'launch', lambda m: m.update(expected_gpu=UUIDS[8]))
        with self.assertRaisesRegex(ValueError, 'GPU differs'):
            runner.check_ready(self.root, self.case)

    def test_gpu_uuid_validation(self):
        self.assertEqual(runner.gpu_uuid(UUIDS[0]), runner.gpu_uuid(UUIDS[0][4:].upper()))
        for value in ('0', 'GPU-short', 'MIG-123'):
            with self.assertRaises(ValueError):
                runner.gpu_uuid(value)

    def test_runtime_gpu_affinity_commands(self):
        cfg = dict(profile=dict(runtime='podman-hpc', network='slirp4netns',
                                container_python='/usr/bin/python3'), image='image',
                   torch_threads=1, wirecell_path='/cfg', wirecell_data='/data')
        for runtime in ('podman-hpc', 'docker', 'apptainer'):
            cfg['profile']['runtime'] = runtime
            with patch.dict(os.environ, CUDA_VISIBLE_DEVICES=UUIDS[0]):
                cmd = runner.runtime_command(self.root, cfg, self.case, 'round', 0, [2, 4])
            self.assertIn('CUDA_VISIBLE_DEVICES='+UUIDS[0], cmd)
            self.assertIn('/usr/bin/python3', cmd)
            self.assertIn('taskset', cmd)
            self.assertIn('2,4', cmd)
            if runtime != 'apptainer':
                self.assertEqual(cmd[cmd.index('--cpuset-cpus')+1], '2,4')
                self.assertIn('--cidfile', cmd)
            if runtime == 'docker':
                self.assertIn('device='+UUIDS[0], cmd)
            if runtime == 'podman-hpc':
                self.assertIn('--gpu', cmd)
        with patch.dict(os.environ, CUDA_VISIBLE_DEVICES='0,1'):
            with self.assertRaises(ValueError):
                runner.runtime_command(self.root, cfg, self.case, 'round', 0, [2])

    def test_local_rank_overrides_inherited_slurm_rank(self):
        runner.save(self.root/'campaign.json', dict(cases=[self.case], profile=dict(runtime='podman-hpc')))
        (self.root/'round').mkdir()
        args = type('Args', (), dict(campaign=self.root, case='fixture', round='round'))()
        with patch.dict(os.environ, PDHD_RANK='1', SLURM_PROCID='0', CUDA_VISIBLE_DEVICES='0'), \
             patch.object(runner.os, 'sched_getaffinity', return_value={1, 3}), \
             patch.object(runner, 'physical_cpus', return_value=[1, 3]), \
             patch.object(runner, 'cpu_identity', side_effect=lambda cpu: [0, cpu]), \
             patch.object(runner, 'assigned_gpu', return_value=UUIDS[0]), \
             patch.object(runner, 'runtime_command', return_value=['fake-runtime']), \
             patch.object(runner.subprocess, 'Popen') as popen, patch.object(runner, 'stop_runtime'):
            popen.return_value.wait.return_value = 0
            runner.host_rank(args)
        self.assertTrue((self.root/'round/rank1/launch.json').exists())
        self.assertFalse((self.root/'round/rank0').exists())

    def test_runtime_success_does_not_kill_persistent_fuse_helpers(self):
        with patch.object(runner.os, 'killpg') as killpg:
            process = unittest.mock.Mock()
            process.poll.return_value = 0
            runner.stop_runtime(process)
            process.terminate.assert_not_called()
            killpg.assert_not_called()

    def test_runtime_cancel_targets_client_not_helper_group(self):
        with patch.object(runner.os, 'killpg') as killpg:
            process = unittest.mock.Mock()
            process.poll.return_value = None
            runner.stop_runtime(process)
            process.terminate.assert_called_once()
            killpg.assert_not_called()

    def test_signal_handler_restored(self):
        previous = signal.getsignal(signal.SIGTERM)
        with self.assertRaisesRegex(RuntimeError, 'signal'):
            with runner.cancellation_signals():
                os.kill(os.getpid(), signal.SIGTERM)
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

    def test_cleanup_escalates_sigterm_ignoring_child(self):
        marker = self.root/'ready'
        program = ('import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                   f'pathlib.Path({str(marker)!r}).touch(); time.sleep(60)')
        child = subprocess.Popen([sys.executable, '-c', program], start_new_session=True)
        try:
            deadline = time.monotonic()+5
            while not marker.exists() and time.monotonic()<deadline:
                time.sleep(.01)
            self.assertTrue(marker.exists())
            runner.stop(child, grace=.1)
            self.assertEqual(child.returncode, -signal.SIGKILL)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()

    def test_cleanup_after_group_leader_exits(self):
        pidfile = self.root/'pid'
        program = ('import subprocess,pathlib; '
                   'p=subprocess.Popen(["sleep","60"]); '
                   f'pathlib.Path({str(pidfile)!r}).write_text(str(p.pid))')
        leader = subprocess.Popen([sys.executable, '-c', program], start_new_session=True)
        leader.wait(timeout=5)
        descendant = int(pidfile.read_text())
        try:
            runner.stop(leader, grace=.1)
            deadline = time.monotonic()+3
            while time.monotonic()<deadline:
                state = Path(f'/proc/{descendant}/stat')
                if not state.exists() or state.read_text().split()[2] == 'Z':
                    break
                time.sleep(.02)
            else:
                self.fail('Descendant survived exited group leader cleanup')
        finally:
            try:
                os.kill(descendant, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_failure_writes_record_and_stops_launcher(self):
        cfg = dict(launcher='slurm', barrier_timeout=1, profile=dict(runtime='podman-hpc'))
        case = dict(self.case, slurm_cpus_per_task=2)
        with patch.object(runner.subprocess, 'Popen') as popen, patch.object(runner, 'stop') as stop:
            popen.return_value.poll.return_value = 1
            with self.assertRaisesRegex(RuntimeError, 'before ready'):
                runner.launch_round(self.root, cfg, case, 'failure', [])
            stop.assert_called_once_with(popen.return_value, grace=60)
        self.assertTrue((self.root/'rounds/fixture/failure/failed.json').exists())

    def test_remote_cleanup_targets_actual_hosts_without_gpus(self):
        cfg = dict(profile=dict(runtime='podman-hpc'))
        with patch.object(runner.subprocess, 'run') as run:
            run.return_value.returncode = 0
            runner.remote_cleanup(self.root, cfg, self.case, '.')
        cmd = run.call_args[0][0]
        self.assertIn('--overlap', cmd)
        self.assertIn('--gpus-per-task=0', cmd)
        self.assertEqual(cmd[cmd.index('--nodelist')+1], 'node0,node1')
        self.assertIn('_cleanup', cmd)

    def test_host_cleanup_only_stops_its_own_container(self):
        cfg = dict(profile=dict(runtime='podman-hpc'))
        for rank in (0, 1):
            self.change(rank, 'launch', lambda m: m.update(host=runner.socket.gethostname()))
            (self.root/f'rank{rank}/container.cid').write_text(f'cid{rank}')
        with patch.object(runner.subprocess, 'run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, '', '')
            runner.cleanup_containers(self.root, cfg, '.', rank=0)
        commands = [call[0][0] for call in run.call_args_list]
        self.assertEqual(commands[0][-1], 'cid0')
        self.assertFalse(any('cid1' in cmd for cmd in commands))
        self.assertTrue(runner.read(self.root/'rank0/cleanup.json')['removed'])

    def test_cancel_removes_campaign_lock(self):
        runner.save(self.root/'campaign.json', dict(cases=[self.case], launcher='local', hashes={}))
        args = type('Args', (), dict(campaign=self.root, cases=None))()
        with patch.object(runner, 'run_cases', side_effect=lambda *_: os.kill(os.getpid(), signal.SIGTERM)):
            with self.assertRaisesRegex(RuntimeError, 'signal'):
                runner.run(args)
        self.assertFalse((self.root/'.running').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
