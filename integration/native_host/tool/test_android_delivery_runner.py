"""Offline checks for evidence publication after exact private-file cleanup."""

import json
import io
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import run_android_delivery_validation as r


class FinishTests(unittest.TestCase):
    def run_finish(self, root, *, fail_cleanup):
        target = root / 'private-target.json'
        receipt = root / 'private-receipt.json'
        target.write_text('private test fixture')
        receipt.write_text('private test fixture')
        device = mock.Mock()
        if fail_cleanup:
            device.must.side_effect = lambda arguments: (
                (_ for _ in ()).throw(r.h.ValidationFailure('cleanup_failed'))
                if 'rm' in arguments else ''
            )
        result = {'phase': 'complete', 'gates': sorted(r.GATES), 'backend_device_id': 123}
        metadata = {'background_process_killed': True, 'started_utc': 'test', 'apk_sha256': 'test'}
        with mock.patch.object(r, 'status', return_value=result), \
                mock.patch.object(r, 'private_json', return_value=metadata), \
                mock.patch.object(r, 'TARGET', target), \
                mock.patch.object(r, 'RECEIPT', receipt), \
                mock.patch.object(r.h, 'HOST', root):
            if fail_cleanup:
                with self.assertRaises(r.h.ValidationFailure):
                    r.finish(device)
            else:
                with redirect_stdout(io.StringIO()):
                    r.finish(device)
        return target, receipt

    def test_cleanup_failure_does_not_publish_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.run_finish(root, fail_cleanup=True)
            self.assertFalse((root / 'evidence/android-firebase-delivery-20261014.json').exists())

    def test_pass_requires_remote_and_local_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, receipt = self.run_finish(root, fail_cleanup=False)
            self.assertFalse(target.exists())
            self.assertFalse(receipt.exists())
            report = json.loads((root / 'evidence/android-firebase-delivery-20261014.json').read_text())
            self.assertTrue(report['private_input_and_state_absent'])
            self.assertEqual(set(report['gates']), r.GATES)


if __name__ == '__main__':
    unittest.main()
