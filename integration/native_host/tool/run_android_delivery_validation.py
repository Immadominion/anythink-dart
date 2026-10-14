#!/usr/bin/env python3
"""Stage real FCM background/restart taps without automating phone UI.

Build integration_test/firebase_delivery_host.dart first. The user presses Home
and taps each exact single-device console message. Only the dedicated app is
installed, launched or killed; am kill is used only after its actual paused gate.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import time

import session_validation_support as h
from run_android_firebase_validation import private_json
from run_native_resilience_validation import ANDROID_PACKAGE, Device

INPUT = 'cache/anythink-delivery-input.json'
STATE = 'cache/anythink-delivery-state.json'
RESULT = 'cache/anythink-delivery-result.json'
GATES = {
    'real_token_and_backend_registration',
    'backend_session_revoked_before_delivery',
    'actual_os_background_transition',
    'actual_background_notification_tap_via_adapter',
    'actual_terminated_notification_launch',
    'terminated_initial_message_consumed_once',
    'test_token_retired_and_private_state_removed',
}
SECRET_DIR = h.HOST.parents[1] / '.secrets/firebase-sdk'
RECEIPT = SECRET_DIR / 'delivery-run-receipt.json'
TARGET = SECRET_DIR / 'delivery-test-token.json'


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
    os.chmod(path, 0o600)


def read_remote(device, path):
    return json.loads(device.must(['shell', 'run-as', ANDROID_PACKAGE, 'cat', path]))


def prepare(device):
    config = private_json(SECRET_DIR.parent / 'live-contract.json')
    firebase = private_json(SECRET_DIR / 'google-services.json')
    if config.get('api_origin') != h.ORIGIN or str(config.get('project_id')) != h.PROJECT:
        raise h.ValidationFailure('dedicated_backend_required')
    clients = firebase['client']
    if firebase['project_info']['project_id'] != 'aura-the-app' or len(clients) != 1 or clients[0]['client_info']['android_client_info']['package_name'] != ANDROID_PACKAGE:
        raise h.ValidationFailure('dedicated_firebase_app_required')
    apk = h.HOST / 'build/app/outputs/flutter-apk/app-debug.apk'
    code, result = h.captured(device.prefix + ['install', '-r', str(apk)], timeout=120)
    if code or 'Success' not in result:
        raise h.ValidationFailure('test_host_install_failed')
    device.stop()
    for file in [INPUT, STATE, RESULT]:
        device.must(['shell', 'run-as', ANDROID_PACKAGE, 'test', '!', '-e', file])
    user = config['users'][0]
    payload = {
        'api_origin': h.ORIGIN, 'project_id': h.PROJECT,
        'email': user['email'], 'password': user['password'],
        'firebase': {
            'apiKey': clients[0]['api_key'][0]['current_key'],
            'appId': clients[0]['client_info']['mobilesdk_app_id'],
            'projectId': firebase['project_info']['project_id'],
            'messagingSenderId': firebase['project_info']['project_number'],
        },
    }
    device.must([
        'shell', 'run-as', ANDROID_PACKAGE, 'sh', '-c',
        shlex.quote('umask 077; cat > ' + INPUT),
    ], payload=json.dumps(payload).encode())
    if device.must(['shell', 'run-as', ANDROID_PACKAGE, 'stat', '-c', '%a', INPUT]).strip() != '600':
        raise h.ValidationFailure('input_mode_invalid')
    write_private(RECEIPT, {
        'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'background_process_killed': False,
    })
    device.must(['shell', 'am', 'start', '-n', ANDROID_PACKAGE + '/.MainActivity'])
    print('DELIVERY_PREPARED real-provider host launched; awaiting its status')


def status(device):
    result = read_remote(device, RESULT)
    phase = result.get('phase')
    allowed = {'awaiting_notification_permission', 'awaiting_first_home', 'background_ready', 'awaiting_second_home', 'terminated_ready', 'complete', 'failed'}
    if phase not in allowed:
        raise h.ValidationFailure('unexpected_delivery_phase')
    gates = result.get('gates')
    if not isinstance(gates, list) or not set(gates) <= GATES:
        raise h.ValidationFailure('unexpected_delivery_gates')
    if phase in {'background_ready', 'awaiting_second_home', 'terminated_ready'}:
        state = read_remote(device, STATE)
        token = state.get('token')
        if not isinstance(token, str) or not token:
            raise h.ValidationFailure('private_target_missing')
        write_private(TARGET, {'token': token, 'stage': phase})
    # Only fixed states, gates and the disposable backend record ID are printed.
    print(json.dumps({
        'phase': phase, 'gates': gates,
        'backend_device_id': result.get('backend_device_id'),
    }))
    return result


def kill_background(device):
    result = status(device)
    if result['phase'] != 'terminated_ready':
        raise h.ValidationFailure('actual_background_phase_required')
    before = device.must(['shell', 'pidof', ANDROID_PACKAGE]).strip()
    if not before:
        raise h.ValidationFailure('host_already_absent')
    # am kill kills only background processes; unlike force-stop, it does not
    # mark this package stopped and prevent the intended FCM notification.
    device.must(['shell', 'am', 'kill', ANDROID_PACKAGE])
    for _ in range(10):
        code, pids = h.captured(device.prefix + ['shell', 'pidof', ANDROID_PACKAGE])
        if code and not pids.strip():
            break
        time.sleep(0.3)
    else:
        raise h.ValidationFailure('background_process_survived_kill')
    receipt = private_json(RECEIPT)
    receipt['background_process_killed'] = True
    write_private(RECEIPT, receipt)
    print('DELIVERY_TERMINATED background SDK process exited; ready for one restart notification')


def finish(device):
    result = status(device)
    receipt = private_json(RECEIPT)
    if result['phase'] != 'complete' or set(result['gates']) != GATES or not receipt.get('background_process_killed'):
        raise h.ValidationFailure('delivery_gates_incomplete')
    for file in [INPUT, STATE]:
        device.must(['shell', 'run-as', ANDROID_PACKAGE, 'test', '!', '-e', file])
    report = {
        'platform': 'Android', 'device': 'Seeker', 'real_firebase': True,
        'manual_user_home_and_notification_taps': True,
        'background_process_killed_without_force_stop': True,
        'gates': sorted(GATES), 'backend_device_id': result['backend_device_id'],
        'started_utc': receipt['started_utc'],
        'completed_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'apk_sha256': receipt['apk_sha256'], 'private_input_and_state_absent': True,
    }
    TARGET.unlink(missing_ok=True)
    RECEIPT.unlink(missing_ok=True)
    device.must(['shell', 'run-as', ANDROID_PACKAGE, 'rm', '-f', RESULT])
    device.must(['shell', 'run-as', ANDROID_PACKAGE, 'test', '!', '-e', RESULT])
    if TARGET.exists() or RECEIPT.exists():
        raise h.ValidationFailure('local_private_handoff_survived')
    report_path = h.HOST / 'evidence/android-firebase-delivery-20261014.json'
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print('DELIVERY_PASS background tap and terminated launch verified; private state cleared')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'status', 'kill-background', 'finish'])
    args = parser.parse_args()
    device = Device('android')
    {'prepare': prepare, 'status': status, 'kill-background': kill_background, 'finish': finish}[args.action](device)


if __name__ == '__main__':
    try:
        main()
    except h.ValidationFailure as error:
        print('DELIVERY_FAILED ' + str(error))
        raise SystemExit(1) from None
    except Exception:
        print('DELIVERY_FAILED unexpected_redacted')
        raise SystemExit(1) from None
