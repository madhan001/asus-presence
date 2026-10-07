"""Unit tests for asus-presence-ctl's status word (what the tray icon shows).

Run: python3 -m unittest discover -s tests -v   (from the repository root)
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("ctl", os.path.join(HERE, "..", "asus-presence-ctl"))
_spec = importlib.util.spec_from_loader("ctl", _loader)
ctl = importlib.util.module_from_spec(_spec)
_loader.exec_module(ctl)

ACTIVE = {"mode": "active", "sensor": "iio:device1", "sensor_ready": True}


class StatusTests(unittest.TestCase):
    def test_off(self):
        self.assertEqual(ctl.status(None), "off")
        self.assertEqual(ctl.status({"mode": "stopped", "sensor": None}), "off")
        self.assertEqual(ctl.status(dict(ACTIVE, sensor=None)), "off")   # no sensor found

    def test_standby_and_starting(self):
        self.assertEqual(ctl.status(dict(ACTIVE, mode="standby")), "standby")
        self.assertEqual(ctl.status(dict(ACTIVE, sensor_ready=False)), "starting")

    def test_presence(self):
        self.assertEqual(ctl.status(dict(ACTIVE, present=False)), "away")
        self.assertEqual(ctl.status(dict(ACTIVE, present=True, attention=False)), "present")
        self.assertEqual(ctl.status(dict(ACTIVE, present=True, attention=True)), "looking")


if __name__ == "__main__":
    unittest.main()
