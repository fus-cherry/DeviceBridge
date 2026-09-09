"""Real URLSession WebSocket boundary checks; synthetic loopback servers, no device or real URI."""
import base64
import hashlib
import http.server
import json
from pathlib import Path
import struct
import subprocess
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Endpoint(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        if self.server.redirect is not None:
            status, port = self.server.redirect
            self.send_response(status)
            self.send_header("Location", f"http://127.0.0.1:{port}/synthetic-only/ws")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.server.accept:
            key = self.headers.get("Sec-WebSocket-Key", "")
            digest = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.protocol_version = "HTTP/1.1"
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
            self.end_headers()
            self.connection.settimeout(3)
            header = self.rfile.read(2)
            if len(header) != 2 or header[0] != 0x81 or not header[1] & 0x80:
                return
            length = header[1] & 127
            if length == 126:
                length = struct.unpack("!H", self.rfile.read(2))[0]
            if length > 4096 or length == 127:
                return
            mask = self.rfile.read(4)
            payload = self.rfile.read(length)
            request = json.loads(bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))
            self.server.methods.append(request.get("method"))
            if request.get("method") != "getVM":
                return
            response = json.dumps({"jsonrpc": "2.0", "id": request["id"],
                                   "result": {"type": "VM", "pid": 123}}, separators=(",", ":")).encode()
            self.wfile.write(bytes([0x81, len(response)]) + response)
            self.wfile.flush()
            self.close_connection = True
            return
        self.send_response(403)
        self.send_header("Content-Length", "0")
        self.end_headers()


class VMTransportRedirectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build = subprocess.run(["swift", "build", "--package-path", "packages/DeviceBridgeCore",
                                "--product", "DeviceBridgeCoreChecks"], cwd=ROOT,
                               capture_output=True, text=True, timeout=300)
        if build.returncode:
            raise RuntimeError(build.stdout[-4000:] + build.stderr[-4000:])
        binary = subprocess.check_output(["swift", "build", "--package-path", "packages/DeviceBridgeCore",
                                          "--show-bin-path"], cwd=ROOT, text=True).strip()
        cls.executable = str(Path(binary) / "VMRedirectProbe")
        subprocess.run(["python3", "scripts/compile-core-check.py", binary,
                        "scripts/ios-vm-spike/RedirectProbe.swift", "-o", cls.executable],
                       cwd=ROOT, check=True, timeout=90)

    def endpoint(self, *, accept=False, redirect=None):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
        server.requests, server.methods = [], []
        server.accept, server.redirect = accept, redirect
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def close():
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        self.addCleanup(close)
        return server

    def run_probe(self, server, *, existing_redirects=False):
        command = [self.executable, str(server.server_port)]
        if existing_redirects:
            command.append("--existing-redirects")
        result = subprocess.run(command, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.requests, ["/synthetic-only/ws"])
        return result.stdout.strip()

    def test_direct_websocket_still_returns_metadata(self):
        origin = self.endpoint(accept=True)
        self.assertEqual(self.run_probe(origin), "Synthetic getVM returned: true")
        self.assertEqual(origin.methods, ["getVM"])

    def test_existing_client_keeps_dds_redirect_compatibility(self):
        destination = self.endpoint(accept=True)
        origin = self.endpoint(redirect=(302, destination.server_port))
        self.assertEqual(self.run_probe(origin, existing_redirects=True), "Synthetic getVM returned: true")
        self.assertEqual(destination.methods, ["getVM"])

    def test_redirect_cannot_escape_owned_endpoint(self):
        destination = self.endpoint()
        for status in [301, 302, 303, 307, 308]:
            with self.subTest(status=status):
                origin = self.endpoint(redirect=(status, destination.server_port))
                self.assertEqual(self.run_probe(origin), "Synthetic getVM returned: false")
                self.assertEqual(destination.requests, [], "redirect escaped the owned route")


if __name__ == "__main__":
    unittest.main()
