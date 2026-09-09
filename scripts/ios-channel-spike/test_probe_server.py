"""Real local Swift-server sockets, headless. No XCTest, signing or phone required."""
import json
import os
import socket
import struct
import subprocess
import time
import unittest
from usbmux_probe import send_frame, receive_frame


class ProbeServerTests(unittest.TestCase):
    def start_server(self, lease=1):
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        process = subprocess.Popen([os.environ['DEVICEBRIDGE_PROBE_SERVER'], str(port), str(lease)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop_process, process)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and process.poll() is None:
            try:
                stream = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                self.addCleanup(stream.close)
                return process, stream
            except ConnectionRefusedError:
                time.sleep(0.01)
        self.fail("Expected identity listener to become reachable; implementation did not open it")

    @staticmethod
    def stop_process(process):
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=3)

    @staticmethod
    def request(sequence=1, action="identity", canary="public-test-canary"):
        return {"version": 1, "sequence": sequence, "action": action, "canary": canary}

    def test_persistent_identity_exchange_then_stop_closes_socket(self):
        process, stream = self.start_server()
        for sequence in (1, 2, 3):
            send_frame(stream, self.request(sequence))
            reply = receive_frame(stream)
            self.assertEqual(reply['sequence'], sequence)
            self.assertEqual(reply['canary'], 'public-test-canary')
            self.assertEqual(reply['status'], 'identity-only')
        send_frame(stream, self.request(4, "stop"))
        self.assertEqual(receive_frame(stream)['status'], 'stopped')
        self.assertEqual(stream.recv(1), b'')
        self.assertEqual(process.wait(timeout=2), 0)

    def test_split_and_coalesced_frames_are_not_misparsed(self):
        process, stream = self.start_server()
        first = json.dumps(self.request()).encode()
        wire = struct.pack('>I', len(first)) + first
        for piece in (wire[:1], wire[1:3], wire[3:9], wire[9:]):
            stream.sendall(piece)
        self.assertEqual(receive_frame(stream)['sequence'], 1)
        frames = []
        for sequence in (2, 3):
            body = json.dumps(self.request(sequence)).encode()
            frames.append(struct.pack('>I', len(body)) + body)
        stream.sendall(b''.join(frames))
        self.assertEqual([receive_frame(stream)['sequence'], receive_frame(stream)['sequence']], [2, 3])

    def test_content_action_is_rejected_and_listener_exits(self):
        process, stream = self.start_server()
        send_frame(stream, self.request(action='clipboard.read'))
        self.assertEqual(stream.recv(1), b'')
        self.assertEqual(process.wait(timeout=2), 0)

    def test_wrong_canary_and_replay_are_rejected(self):
        for replay in (False, True):
            with self.subTest(replay=replay):
                process, stream = self.start_server()
                if replay:
                    send_frame(stream, self.request())
                    receive_frame(stream)
                send_frame(stream, self.request(canary='public-test-canary' if replay else 'other-public-canary'))
                self.assertEqual(stream.recv(1), b'')
                self.assertEqual(process.wait(timeout=2), 0)

    def test_excessive_length_is_rejected_without_waiting_for_body(self):
        process, stream = self.start_server()
        stream.sendall(b'\x00\x00\x10\x01')
        self.assertEqual(stream.recv(1), b'')
        self.assertEqual(process.wait(timeout=2), 0)

    def test_idle_or_partial_frame_expires_without_host_heartbeat(self):
        for partial in (b'', b'\x00\x00'):
            with self.subTest(partial=partial):
                process, stream = self.start_server(lease=0.2)
                stream.sendall(partial)
                self.assertEqual(process.wait(timeout=2), 0)
                self.assertEqual(stream.recv(1), b'')


if __name__ == '__main__':
    unittest.main()
