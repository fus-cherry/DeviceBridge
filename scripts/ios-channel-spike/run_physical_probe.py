"""Opt-in T082 USB experiment using already signed Debug products; no content commands.

Requires an explicit CoreDevice details JSON for the designated phone and a signed products path.
Only a NON-SECRET canary enters TEST_RUNNER_. Never use this bootstrap for a real session nonce.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import statistics
import subprocess
import tempfile
import time
import uuid
from usbmux_probe import connect_usb, send_frame, receive_frame


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--details-json', type=Path, required=True)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--mode', choices=['stop', 'orphan', 'reject'], default='stop')
    parser.add_argument('--home', action='store_true', help='Press Home on the designated phone before listening')
    args = parser.parse_args()
    details = json.loads(args.details_json.read_text())['result']
    connection = details['connectionProperties']
    if connection.get('transportType') != 'wired' or connection.get('pairingState') != 'paired':
        raise RuntimeError('Expected the designated paired wired device; refresh details first')
    serial = details['hardwareProperties']['udid']
    runs = list(args.products.glob('*.xctestrun'))
    if len(runs) != 1:
        raise RuntimeError('Expected exactly one signed test product')
    # Baseline also refuses to replace or interact with an existing listener.
    try:
        with connect_usb(serial, 49871):
            raise RuntimeError('Probe port already in use; no test was launched')
    except ConnectionRefusedError:
        pass

    output = Path(tempfile.mkdtemp(prefix='devicebridge-usb-spike-'))
    result = output / 'result.xcresult'
    config = plistlib.loads(runs[0].read_bytes())

    def configure(value):
        if isinstance(value, dict):
            value = {key: configure(item) for key, item in value.items()}
            if 'TestBundlePath' in value:
                value['SystemAttachmentLifetime'] = 'keepNever'
                value['UserAttachmentLifetime'] = 'keepNever'
            return value
        if isinstance(value, list):
            return [configure(item) for item in value]
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(args.products.resolve()))
        return value

    configuration = output / 'probe.xctestrun'
    configuration.write_bytes(plistlib.dumps(configure(config)))
    # This marker is intentionally non-secret so persistence can be investigated safely.
    canary = 'PUBLIC-T082-CANARY-' + uuid.uuid4().hex
    environment = dict(os.environ)
    expected = {'stop': 'stopped', 'orphan': 'leaseExpired', 'reject': 'invalidRequest'}[args.mode]
    for key, value in {'DEVICEBRIDGE_IDENTITY_PROBE': '1', 'DEVICEBRIDGE_PUBLIC_CANARY': canary,
                       'DEVICEBRIDGE_PROBE_PORT': '49871', 'DEVICEBRIDGE_PROBE_EXPECTED_EXIT': expected,
                       'DEVICEBRIDGE_PROBE_HOME': '1' if args.home else '0'}.items():
        environment['TEST_RUNNER_' + key] = value
    command = ['xcrun', 'xcodebuild', 'test-without-building', '-xctestrun', str(configuration),
               '-destination', 'id=' + serial, '-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/testUSBIdentityProbe',
               '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result)]
    stream = None
    print('Starting selected iPhone identity-only test; no desktop UI automation', flush=True)
    print('Local diagnostic directory: ' + str(output), flush=True)
    with (output / 'xcodebuild.log').open('wb') as log:
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('XCTest exited before opening its USB listener')
                try:
                    stream = connect_usb(serial, 49871)
                    break
                except ConnectionRefusedError:
                    time.sleep(0.25)
            if stream is None:
                raise RuntimeError('USB listener startup deadline exceeded')
            started = time.monotonic()
            latencies = []
            for sequence in range(1, 31):
                begin = time.monotonic()
                send_frame(stream, {'version': 1, 'sequence': sequence, 'action': 'identity', 'canary': canary})
                reply = receive_frame(stream)
                if (reply.get('version'), reply.get('sequence'), reply.get('status'), reply.get('canary'),
                    reply.get('listener'), reply.get('probeOnly')) != (1, sequence, 'identity-only', canary, '127.0.0.1', True):
                    raise RuntimeError('Identity-only response correlation failed')
                latencies.append((time.monotonic() - begin) * 1000)
            print('USB identity exchange: 30 correlated replies; median_ms=%.2f max_ms=%.2f' %
                  (statistics.median(latencies), max(latencies)), flush=True)
            if args.mode == 'stop':
                # Metadata-only renewals exceed one 30-second lease without reinstall/reconnect.
                for sequence in range(31, 38):
                    time.sleep(5)
                    send_frame(stream, {'version': 1, 'sequence': sequence, 'action': 'identity', 'canary': canary})
                    reply = receive_frame(stream)
                    if reply.get('canary') != canary or reply.get('sequence') != sequence:
                        raise RuntimeError('Persistent response correlation failed')
                send_frame(stream, {'version': 1, 'sequence': 38, 'action': 'stop', 'canary': canary})
                if receive_frame(stream).get('status') != 'stopped':
                    raise RuntimeError('Stop acknowledgement missing')
            elif args.mode == 'reject':
                # Unknown action contains no payload; it must terminate, never dispatch content.
                send_frame(stream, {'version': 1, 'sequence': 31, 'action': 'unsupported.probe', 'canary': canary})
            stream.settimeout(40 if args.mode == 'orphan' else 5)
            if stream.recv(1) != b'':
                raise RuntimeError('Expected channel EOF after terminal event')
            print('Terminal socket EOF: %s after %.2fs' % (expected, time.monotonic() - started), flush=True)
            stream.close()
            stream = None
            code = process.wait(timeout=45)
            if code != 0:
                raise RuntimeError('Physical XCTest did not pass; inspect local redacted diagnostics')
            # Re-enumerate exact USB route, then verify the experiment listener is gone.
            try:
                with connect_usb(serial, 49871):
                    raise RuntimeError('Probe listener survived terminal cleanup')
            except ConnectionRefusedError:
                print('Cleanup: exact selected USB route remains; probe port is closed', flush=True)
        finally:
            if stream is not None:
                stream.close()
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)

    summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result),
                              '--format', 'json'], capture_output=True, timeout=20, check=True)
    summary = json.loads(summary.stdout)
    if summary.get('result') != 'Passed' or summary.get('passedTests') != 1 or summary.get('skippedTests') != 0:
        raise RuntimeError('Expected one executed passing physical test, not a skip')
    print('Physical XCTest: 1 passed, 0 failed, 0 skipped', flush=True)
    audit = {'xcodebuild_stdout': canary.encode() in (output / 'xcodebuild.log').read_bytes(),
             'authored_xctestrun': canary.encode() in configuration.read_bytes()}
    for kind in ('console', 'action', 'build'):
        exported = subprocess.run(['xcrun', 'xcresulttool', 'get', 'log', '--path', str(result), '--type', kind],
                                  capture_output=True, timeout=20)
        audit['xcresult_' + kind] = canary.encode() in exported.stdout if exported.returncode == 0 else 'unavailable'
    print('Public canary persistence audit (true means found): ' + json.dumps(audit), flush=True)
    print('This is transport evidence only, NOT authenticated content readiness or Wi-Fi qualification.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError, EOFError, subprocess.SubprocessError) as error:
        # External tool output and device/nonce values are never echoed by the error boundary.
        print('PROBE FAILED: ' + type(error).__name__ + '; see local diagnostic directory above', flush=True)
        raise SystemExit(1)
