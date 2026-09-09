"""Opt-in personal-signed iPhone USB mTLS experiment, public identity traffic only.

Private keys exist only inside Swift host/runner processes. Python sees public bootstrap metadata
and relays opaque TLS bytes. This harness never enables production device-content capabilities.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import select
import signal
import socket
import statistics
import subprocess
import tempfile
import threading
import time
from usbmux_probe import connect_usb


def stop_child(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def configure(value, products):
    if isinstance(value, dict):
        result = {key: configure(item, products) for key, item in value.items()}
        if 'TestBundlePath' in result:
            result['SystemAttachmentLifetime'] = 'keepNever'
            result['UserAttachmentLifetime'] = 'keepNever'
        return result
    if isinstance(value, list):
        return [configure(item, products) for item in value]
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products.resolve()))
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--details-json', type=Path, required=True)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--host-probe', type=Path, required=True)
    parser.add_argument('--native-usb-probe', type=Path,
                        help='Use the Swift exact-USB/half-close relay instead of the legacy Python relay')
    parser.add_argument('--mode', choices=['normal', 'heartbeat', 'orphan', 'invalid', 'disconnect', 'partial', 'identity'], default='normal')
    args = parser.parse_args()
    details = json.loads(args.details_json.read_text())['result']
    properties = details['connectionProperties']
    if properties.get('transportType') != 'wired' or properties.get('pairingState') != 'paired':
        raise RuntimeError('Refresh paired wired device details first')
    serial = details['hardwareProperties']['udid']
    runs = list(args.products.glob('*.xctestrun'))
    if len(runs) != 1:
        raise RuntimeError('Expected one exact signed test product')
    try:
        with connect_usb(serial, 49872):
            raise RuntimeError('Experiment port already occupied; no launch')
    except ConnectionRefusedError:
        pass
    output = Path(tempfile.mkdtemp(prefix='devicebridge-mtls-spike-'))
    print('Secure physical identity experiment; local diagnostics: ' + str(output), flush=True)
    host = runner = None
    native = None
    usb = proxy = None
    relay_thread = None
    relay_errors = []
    encrypted_bytes = bytearray()
    native_failed = False
    try:
        host = subprocess.Popen([str(args.host_probe.resolve()), args.mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        if not select.select([host.stdout], [], [], 10)[0]:
            raise RuntimeError('Host identity creation timeout')
        public = json.loads(host.stdout.readline(16384))
        # A trusted owned host binary emits only these two public values; never a private key.
        if set(public) != {'launchID', 'hostCertificateDER'}:
            raise RuntimeError('Unexpected host public schema')
        import uuid
        launch = str(uuid.UUID(public['launchID'])).upper()
        environment = dict(os.environ)
        expected_server = {'normal': 'tls13-31-exchanges', 'heartbeat': 'tls13-31-exchanges',
                           'identity': 'identity-2-exchanges',
                           'orphan': 'leaseExpired', 'partial': 'leaseExpired', 'invalid': 'invalidFrame', 'disconnect': 'peerClosed'}[args.mode]
        for key, value in {'DEVICEBRIDGE_SECURE_PROBE': '1', 'DEVICEBRIDGE_PUBLIC_LAUNCH': launch,
                           'DEVICEBRIDGE_SECURE_EXPECTED_EXIT': expected_server,
                           'DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE': public['hostCertificateDER']}.items():
            environment['TEST_RUNNER_' + key] = value
        config = output / 'secure.xctestrun'
        config.write_bytes(plistlib.dumps(configure(plistlib.loads(runs[0].read_bytes()), args.products)))
        result = output / 'result.xcresult'
        selected_test = 'testSecureUSBManagedIdentityProbe' if args.mode == 'identity' else 'testSecureUSBIdentityProbe'
        command = ['xcrun', 'xcodebuild', 'test-without-building', '-xctestrun', str(config),
                   '-destination', 'id=' + serial,
                   '-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/' + selected_test,
                   '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result)]
        with (output / 'xcodebuild.log').open('wb') as log:
            runner = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                      start_new_session=True)
        record = output / 'public-bootstrap.json'
        copy_json = output / 'copy-result.json'
        copy_command = ['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', serial,
                        '--domain-type', 'appDataContainer', '--domain-identifier',
                        'dev.debugutility.DeviceBridgeRunnerUITests.xctrunner', '--source',
                        'Documents/DeviceBridgeBootstrap/' + launch + '.json', '--destination', str(record),
                        '--timeout', '5', '--json-output', str(copy_json)]
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if runner.poll() is not None or host.poll() is not None:
                raise RuntimeError('Owning child exited during public bootstrap')
            copied = subprocess.run(copy_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            if copied.returncode == 0 and record.is_file():
                break
            time.sleep(0.3)
        else:
            raise RuntimeError('Exact runner public record unavailable')
        if runner.poll() is not None or host.poll() is not None or record.stat().st_size > 8192:
            raise RuntimeError('Stale/oversized bootstrap')
        if args.native_usb_probe:
            native = subprocess.Popen([str(args.native_usb_probe.resolve())], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
            native.stdin.write(json.dumps({'hardwareUDID': serial, 'launchID': launch}).encode() + b'\n')
            native.stdin.flush()
            if not select.select([native.stdout], [], [], 10)[0]:
                raise RuntimeError('Native USB relay startup timeout')
            listening = json.loads(native.stdout.readline(16384))
            if set(listening) != {'port', 'publicRecord'} or type(listening['port']) is not int or not 0 < listening['port'] <= 65535:
                raise RuntimeError('Native USB relay unavailable')
            if base64.b64decode(listening['publicRecord'], validate=True) != record.read_bytes():
                raise RuntimeError('Native exact-container copy differed from control')
            print('Native exact-container public copy matches control', flush=True)
            port = listening['port']
        else:
            usb = connect_usb(serial, 49872)
            proxy = socket.socket()
            proxy.bind(('127.0.0.1', 0))
            proxy.listen(1)
            proxy.settimeout(10)
            port = proxy.getsockname()[1]

        def relay():
            operation, direction = 'accept', 'none'
            relay_started = time.monotonic()
            forwarded_bytes = 0
            try:
                with proxy.accept()[0] as local:
                    proxy.close()
                    local.settimeout(5)
                    usb.settimeout(5)
                    deadline = time.monotonic() + 90
                    while time.monotonic() < deadline:
                        operation, direction = 'select', 'none'
                        readable, _, _ = select.select([local, usb], [], [], 5)
                        for source in readable:
                            operation = 'recv'
                            direction = 'macToPhone' if source is local else 'phoneToMac'
                            data = source.recv(16384)
                            if not data:
                                return
                            if len(encrypted_bytes) + len(data) > 1024 * 1024:
                                raise RuntimeError('Ciphertext diagnostic bound exceeded')
                            encrypted_bytes.extend(data)
                            operation = 'send'
                            (usb if source is local else local).sendall(data)
                            forwarded_bytes += len(data)
                    operation, direction = 'deadline', 'none'
                    raise TimeoutError('Relay deadline')
            except Exception as error:
                relay_errors.append({'operation': operation, 'direction': direction,
                                     'errorType': type(error).__name__, 'errno': getattr(error, 'errno', None),
                                     'completedForwardBytes': forwarded_bytes,
                                     'elapsedSeconds': round(time.monotonic() - relay_started, 3)})

        if native is None:
            relay_thread = threading.Thread(target=relay, daemon=True)
            relay_thread.start()
        started = time.monotonic()
        answer, _ = host.communicate(input=json.dumps({'port': port, 'record': base64.b64encode(record.read_bytes()).decode()}).encode() + b'\n', timeout=95)
        outcome = json.loads(answer)
        expected_client = {'normal': 'tls13-31-exchanges', 'heartbeat': 'tls13-31-exchanges',
                           'identity': 'identity-2-exchanges',
                           'orphan': 'peerClosed', 'partial': 'peerClosed', 'invalid': 'peerClosed', 'disconnect': 'clientDisconnected'}[args.mode]
        samples = outcome.get('latencyMilliseconds', [])
        print('Bounded client result: ' + json.dumps({
            'result': outcome.get('result'), 'replyCount': len(samples),
            'idleBeforeCloseSeconds': outcome.get('idleBeforeCloseSeconds'),
            'connectedSeconds': outcome.get('connectedSeconds')}), flush=True)
        expected_count = 2 if args.mode == 'identity' else (31 if args.mode in ('normal', 'heartbeat') else 30)
        if host.returncode != 0 or outcome.get('result') != expected_client or len(samples) != expected_count:
            raise RuntimeError('Secure host exchange failed')
        if args.mode in ('orphan', 'partial') and not 28 <= outcome.get('idleBeforeCloseSeconds', -1) <= 35:
            raise RuntimeError('Idle/partial-frame lease outside 30-second tolerance')
        if args.mode == 'heartbeat' and not 38 <= outcome.get('connectedSeconds', -1) <= 60:
            raise RuntimeError('Heartbeat did not survive beyond a complete lease')
        if native is not None:
            terminal, _ = native.communicate(timeout=10)
            relay_result = json.loads(terminal)
            print('Native relay terminal: ' + json.dumps(relay_result), flush=True)
            if native.returncode != 0 or relay_result != {'result': 'clean'}:
                # Preserve failure, but collect the independent phone/cleanup evidence before exiting.
                native_failed = True
        else:
            relay_thread.join(timeout=10)
            if relay_thread.is_alive() or relay_errors:
                print('Relay terminal diagnostics: ' + json.dumps({'threadAlive': relay_thread.is_alive(), 'failures': relay_errors}), flush=True)
                raise RuntimeError('Relay failed or survived exchange')
            usb.close(); usb = None
        print('TLS 1.3: %d correlated exchanges; mode=%s duration=%.2fs median_ms=%.2f max_ms=%.2f' %
              (len(samples), args.mode, time.monotonic() - started, statistics.median(samples), max(samples)), flush=True)
        if runner.wait(timeout=45) != 0:
            raise RuntimeError('Physical XCTest failed')
        summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                            '--path', str(result), '--format', 'json'], timeout=20))
        if summary.get('passedTests') != 1 or summary.get('skippedTests') != 0 or summary.get('result') != 'Passed':
            raise RuntimeError('Expected one executed physical test, not a skip')
        canary = outcome['publicCanary'].encode()
        audit = {'ciphertext_relay': 'notCapturedNative' if native is not None else canary in encrypted_bytes,
                 'public_record': canary in record.read_bytes(),
                 'xcodebuild_stdout': canary in (output / 'xcodebuild.log').read_bytes(),
                 'authored_xctestrun': canary in config.read_bytes()}
        for kind in ('console', 'action', 'build'):
            exported = subprocess.run(['xcrun', 'xcresulttool', 'get', 'log', '--path', str(result), '--type', kind],
                                      capture_output=True, timeout=20)
            audit['xcresult_' + kind] = canary in exported.stdout if exported.returncode == 0 else 'unavailable'
        print('Public marker persistence audit (true means found): ' + json.dumps(audit), flush=True)
        if audit['xcresult_action'] == 'unavailable':
            raise RuntimeError('Required action-log persistence audit unavailable')
        if any(value is True for value in audit.values()):
            raise RuntimeError('Public marker escaped the encrypted test channel')
        try:
            with connect_usb(serial, 49872):
                raise RuntimeError('Listener survived cleanup')
        except ConnectionRefusedError:
            pass
        if native_failed:
            print('Independent evidence: physical XCTest passed and USB listener closed; relay gate FAILED', flush=True)
            raise RuntimeError('Native USB relay failed; not a fully qualified run')
        print('Physical XCTest: 1 passed, 0 skipped; USB listener closed. Content/wireless remain unqualified.', flush=True)
    finally:
        if proxy is not None:
            proxy.close()
        if usb is not None:
            usb.close()
        stop_child(host)
        stop_child(runner)
        stop_child(native)
        if relay_thread is not None:
            relay_thread.join(timeout=6)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('SECURE PROBE FAILED: ' + type(error).__name__ + '; inspect local diagnostics', flush=True)
        if type(error) is RuntimeError:
            # All RuntimeError sites in this harness use fixed, non-sensitive diagnostic messages.
            print(str(error), flush=True)
        raise SystemExit(1)
