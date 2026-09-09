"""T082 identity-only experiment. Not a production or authenticated content channel."""
import json
import plistlib
import socket
import struct
import time


def select_usb(devices, serial):
    def canonical(value):
        if len(value) == 24 and "-" not in value:
            return value[:8] + "-" + value[8:]
        return value
    matches = [d["Properties"] for d in devices
               if canonical(d.get("Properties", {}).get("SerialNumber", "")) == canonical(serial)
               and d.get("Properties", {}).get("ConnectionType") == "USB"]
    if len(matches) != 1:
        raise ValueError("Exact unique USB route unavailable")
    handle = matches[0].get("DeviceID")
    if type(handle) is not int or handle <= 0:
        raise ValueError("Invalid device handle")
    return handle


def receive_exact(stream, length, deadline):
    data = bytearray()
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Frame deadline exceeded")
        stream.settimeout(remaining)
        chunk = stream.recv(length - len(data))
        if not chunk:
            raise EOFError("Incomplete frame")
        data.extend(chunk)
    return bytes(data)


def receive_plist(stream, tag):
    deadline = time.monotonic() + 5
    length, version, kind, reply_tag = struct.unpack("<IIII", receive_exact(stream, 16, deadline))
    if not 16 <= length <= 1048576 or (version, kind, reply_tag) != (1, 8, tag):
        raise ValueError("Invalid usbmux response envelope")
    result = plistlib.loads(receive_exact(stream, length - 16, deadline))
    if not isinstance(result, dict):
        raise ValueError("Invalid usbmux response body")
    return result


def request_plist(stream, body, tag=1):
    payload = plistlib.dumps(dict(body, ClientVersionString="DeviceBridge-T082",
                                 ProgName="DeviceBridgeIdentityProbe", kLibUSBMuxVersion=3))
    stream.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, tag) + payload)
    return receive_plist(stream, tag)


def open_mux():
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        stream.settimeout(5)
        stream.connect("/var/run/usbmuxd")
        return stream
    except BaseException:
        stream.close()
        raise


def connect_usb(serial, port):
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError("Invalid probe port")
    with open_mux() as inventory:
        handle = select_usb(request_plist(inventory, {"MessageType": "ListDevices"})["DeviceList"], serial)
    stream = open_mux()
    try:
        response = request_plist(stream, {"MessageType": "Connect", "DeviceID": handle,
                                          "PortNumber": socket.htons(port)})
        if response.get("Number") != 0:
            raise ConnectionRefusedError("Selected USB probe port unavailable")
        return stream
    except BaseException:
        stream.close()
        raise


def receive_frame(stream):
    deadline = time.monotonic() + 5
    length, = struct.unpack(">I", receive_exact(stream, 4, deadline))
    if not 1 <= length <= 4096:
        raise ValueError("Invalid probe frame length")
    result = json.loads(receive_exact(stream, length, deadline))
    if not isinstance(result, dict):
        raise ValueError("Invalid probe frame body")
    return result


def send_frame(stream, request):
    payload = json.dumps(request, separators=(",", ":")).encode()
    if not 1 <= len(payload) <= 4096:
        raise ValueError("Invalid probe frame length")
    stream.settimeout(5)
    stream.sendall(struct.pack(">I", len(payload)) + payload)
