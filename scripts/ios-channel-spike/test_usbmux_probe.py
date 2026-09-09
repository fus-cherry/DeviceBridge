"""Host-only contract checks; no phone, signing or desktop UI interaction."""
import plistlib
import socket
import struct
import unittest
from usbmux_probe import receive_plist, select_usb, receive_frame


class USBMuxProbeTests(unittest.TestCase):
    def test_selected_device_does_not_fall_back_to_network_or_another_phone(self):
        devices = [
            {"Properties": {"SerialNumber": "selected", "ConnectionType": "Network", "DeviceID": 1}},
            {"Properties": {"SerialNumber": "other", "ConnectionType": "USB", "DeviceID": 2}},
        ]
        with self.assertRaises(ValueError):
            select_usb(devices, "selected")

    def test_duplicate_usb_routes_are_not_arbitrarily_selected(self):
        entry = {"Properties": {"SerialNumber": "selected", "ConnectionType": "USB", "DeviceID": 3}}
        with self.assertRaises(ValueError):
            select_usb([entry, entry], "selected")

    def test_exact_usb_route_is_selected_with_upstream_serial_normalization(self):
        entry = {"Properties": {"SerialNumber": "123456781234567812345678", "ConnectionType": "USB", "DeviceID": 7}}
        self.assertEqual(select_usb([entry], "12345678-1234567812345678"), 7)

    def test_valid_plist_is_returned(self):
        payload = plistlib.dumps({"Number": 0})
        left, right = socket.socketpair()
        with left, right:
            right.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 9) + payload)
            self.assertEqual(receive_plist(left, 9), {"Number": 0})

    def test_bad_headers_are_rejected_before_reading_body(self):
        for header in [(15, 1, 8, 9), (1048577, 1, 8, 9), (20, 0, 8, 9), (20, 1, 7, 9), (20, 1, 8, 8)]:
            with self.subTest(header=header):
                left, right = socket.socketpair()
                with left, right:
                    left.settimeout(0.1)
                    right.sendall(struct.pack("<IIII", *header))
                    with self.assertRaises(ValueError):
                        receive_plist(left, 9)

    def test_truncated_frame_never_succeeds(self):
        left, right = socket.socketpair()
        with left, right:
            right.sendall(b'\x00\x00\x00\x04{}')
            right.shutdown(socket.SHUT_WR)
            with self.assertRaises(EOFError):
                receive_frame(left)

    def test_excessive_frame_rejected_before_allocation(self):
        left, right = socket.socketpair()
        with left, right:
            right.sendall(b'\x00\x00\x10\x01')
            with self.assertRaises(ValueError):
                receive_frame(left)


if __name__ == "__main__":
    unittest.main()
