"""Unit tests for px13-presence-agent's pure policy (decide) and config loading.

Run: python3 -m unittest discover -s tests -v   (from the repository root)
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from dataclasses import replace

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader(
    "agent", os.path.join(HERE, "..", "asus-presence-agent"))
_spec = importlib.util.spec_from_loader("agent", _loader)
agent = importlib.util.module_from_spec(_spec)
_loader.exec_module(agent)

Config, Memory, Sensor, decide = agent.Config, agent.Memory, agent.Sensor, agent.decide

# The looking inhibitions and screen-off are off here so the lock/dim tests see
# only their own actions; LookingTests and ScreenOffTests cover them.
CFG = Config(enabled=True, lock=True, lock_after=60, dim=True, dim_after=10, dim_level=30,
             keep_screen_on=False, prevent_sleep=False, wake_on_return=False, screen_off=False)
ACTIVE = Memory(sensor_mode="active")
T0 = 1000.0


def sensor(present=True, attention=True, away_since=0.0, looking_away_since=0.0):
    return Sensor(ready=True, present=present, attention=attention, away_since=away_since,
                  looking_away_since=looking_away_since, mode="active")


class DimTests(unittest.TestCase):
    def test_no_dim_before_timeout_but_deadline_set(self):
        d = decide(T0 + 5, sensor(attention=False, looking_away_since=T0), False, CFG, ACTIVE)
        self.assertEqual(d.actions, [])
        self.assertEqual(d.wake_at, T0 + 10)

    def test_dims_after_timeout_once(self):
        s = sensor(attention=False, looking_away_since=T0)
        d = decide(T0 + 10, s, False, CFG, ACTIVE)
        self.assertEqual(d.actions, ["dim"])
        again = decide(T0 + 20, s, False, CFG, d.memory)
        self.assertEqual(again.actions, [])

    def test_restores_when_attention_returns(self):
        d = decide(T0 + 30, sensor(attention=True), False, CFG, replace(ACTIVE, dimmed=True))
        self.assertEqual(d.actions, ["restore"])
        self.assertFalse(d.memory.dimmed)

    def test_stays_dimmed_when_walking_away(self):
        d = decide(T0 + 30, sensor(present=False, attention=False, away_since=T0 + 25),
                   False, CFG, replace(ACTIVE, dimmed=True))
        self.assertNotIn("restore", d.actions)

    def test_dim_disabled(self):
        d = decide(T0 + 99, sensor(attention=False, looking_away_since=T0), False,
                   replace(CFG, dim=False), ACTIVE)
        self.assertEqual(d.actions, [])


class LockTests(unittest.TestCase):
    def test_locks_after_away_timeout_once_per_absence(self):
        s = sensor(present=False, attention=False, away_since=T0)
        self.assertEqual(decide(T0 + 59, s, False, CFG, ACTIVE).actions, [])
        d = decide(T0 + 60, s, False, CFG, ACTIVE)
        self.assertEqual(d.actions, ["lock"])
        # Still away (and e.g. the user unlocked remotely): don't lock again.
        self.assertEqual(decide(T0 + 200, s, False, CFG, d.memory).actions, [])
        # A new absence locks again.
        s2 = sensor(present=False, attention=False, away_since=T0 + 500)
        self.assertEqual(decide(T0 + 560, s2, False, CFG, d.memory).actions, ["lock"])

    def test_no_lock_while_present(self):
        d = decide(T0 + 999, sensor(present=True, attention=True), False, CFG, ACTIVE)
        self.assertNotIn("lock", d.actions)

    def test_inhibitor_postpones_lock(self):
        s = sensor(present=False, attention=False, away_since=T0)
        d = decide(T0 + 60, s, False, CFG, ACTIVE, inhibited=True)
        self.assertEqual(d.actions, [])
        self.assertEqual(d.wake_at, T0 + 60 + agent.INHIBIT_RETRY)
        later = decide(T0 + 60 + agent.INHIBIT_RETRY, s, False, CFG, d.memory, inhibited=False)
        self.assertEqual(later.actions, ["lock"])

    def test_sensor_not_ready_never_locks(self):
        d = decide(T0 + 999, Sensor(), False, CFG, ACTIVE)
        self.assertEqual(d.actions, [])


class ScreenOffTests(unittest.TestCase):
    CFG = replace(CFG, lock=False, screen_off=True, screen_off_after=60)

    def test_off_after_timeout_once_per_absence(self):
        s = sensor(present=False, attention=False, away_since=T0)
        early = decide(T0 + 59, s, False, self.CFG, ACTIVE)
        self.assertEqual((early.actions, early.wake_at), ([], T0 + 60))
        d = decide(T0 + 60, s, False, self.CFG, ACTIVE)
        self.assertEqual(d.actions, ["display:off"])
        # Woken by input while the sensor still sees nobody: don't turn it off again.
        self.assertEqual(decide(T0 + 200, s, False, self.CFG, d.memory).actions, [])

    def test_wakes_on_return(self):
        d = decide(T0 + 60, sensor(present=False, attention=False, away_since=T0), False, self.CFG, ACTIVE)
        back = decide(T0 + 90, sensor(present=True, attention=False, looking_away_since=T0 + 90),
                      False, self.CFG, d.memory)
        self.assertEqual(back.actions, ["wake"])
        self.assertEqual(decide(T0 + 91, sensor(present=True), False, self.CFG, back.memory).actions, [])

    def test_inhibitor_postpones(self):
        s = sensor(present=False, attention=False, away_since=T0)
        d = decide(T0 + 60, s, False, self.CFG, ACTIVE, inhibited=True)
        self.assertEqual(d.actions, [])
        later = decide(T0 + 60 + agent.INHIBIT_RETRY, s, False, self.CFG, d.memory)
        self.assertEqual(later.actions, ["display:off"])

    def test_with_lock_at_same_time(self):
        cfg = replace(self.CFG, lock=True, lock_after=60)
        d = decide(T0 + 60, sensor(present=False, attention=False, away_since=T0), False, cfg, ACTIVE)
        self.assertEqual(d.actions, ["lock", "display:off"])

    def test_locking_forgets_it(self):
        d = decide(T0 + 60, sensor(present=False, attention=False, away_since=T0), False, self.CFG, ACTIVE)
        locked = decide(T0 + 100, sensor(present=False, attention=False, away_since=T0), True,
                        self.CFG, d.memory)
        self.assertFalse(locked.memory.screen_off)
        self.assertNotIn("wake", decide(T0 + 200, sensor(), False, self.CFG, locked.memory).actions)

    def test_disabled(self):
        cfg = replace(self.CFG, screen_off=False)
        d = decide(T0 + 999, sensor(present=False, attention=False, away_since=T0), False, cfg, ACTIVE)
        self.assertEqual(d.actions, [])


class OnlyWhenIdleTests(unittest.TestCase):
    CFG = replace(CFG, only_when_idle=True)

    def test_paused_while_using_the_computer(self):
        d = decide(T0, sensor(), False, self.CFG, ACTIVE, user_active=True)
        self.assertEqual(d.actions, ["sensor:paused"])

    def test_turns_on_when_idle(self):
        d = decide(T0, Sensor(mode="paused"), False, self.CFG, Memory(sensor_mode="paused"), user_active=False)
        self.assertEqual(d.actions, ["sensor:active"])

    def test_input_restores_dim_and_drops_holds(self):
        cfg = replace(self.CFG, keep_screen_on=True, prevent_sleep=True)
        mem = replace(ACTIVE, dimmed=True, screen_held=True, sleep_held=True, screen_off=True)
        d = decide(T0, sensor(), False, cfg, mem, user_active=True)
        self.assertEqual(sorted(d.actions), sorted(["sensor:paused", "screen:release", "sleep:release", "restore"]))
        self.assertFalse(d.memory.screen_off)

    def test_stale_sensor_state_never_dims_or_locks_while_typing(self):
        # The service has not caught up yet: the state still says "away" / "looking away".
        away = sensor(present=False, attention=False, away_since=T0 - 999)
        looking_away = sensor(present=True, attention=False, looking_away_since=T0 - 999)
        for s in (away, looking_away):
            d = decide(T0, s, False, self.CFG, Memory(sensor_mode="paused"), user_active=True)
            self.assertEqual(d.actions, [])

    def test_locked_means_standby(self):
        d = decide(T0, sensor(), True, self.CFG, ACTIVE, user_active=True)
        self.assertIn("sensor:standby", d.actions)

    def test_option_off_ignores_input(self):
        d = decide(T0, sensor(), False, CFG, ACTIVE, user_active=True)
        self.assertNotIn("sensor:paused", d.actions)


class LockedSessionTests(unittest.TestCase):
    def test_locked_puts_sensor_in_standby_and_restores_dim(self):
        d = decide(T0, sensor(), True, CFG, replace(ACTIVE, dimmed=True))
        self.assertIn("sensor:standby", d.actions)
        self.assertIn("restore", d.actions)

    def test_unlock_reactivates_sensor(self):
        d = decide(T0, Sensor(mode="standby"), False, CFG, Memory(sensor_mode="standby"))
        self.assertEqual(d.actions, ["sensor:active"])

    def test_wake_on_return_keeps_sensor_and_wakes_once(self):
        cfg = replace(CFG, wake_on_return=True)
        away = decide(T0, sensor(present=False, attention=False), True, cfg, ACTIVE)
        self.assertEqual(away.actions, [])
        back = decide(T0 + 5, sensor(present=True), True, cfg, away.memory)
        self.assertEqual(back.actions, ["wake"])
        self.assertEqual(decide(T0 + 6, sensor(present=True), True, cfg, back.memory).actions, [])


class LookingTests(unittest.TestCase):
    """keep_screen_on / prevent_sleep inhibitions while you look at the screen."""
    BOTH = replace(CFG, keep_screen_on=True, prevent_sleep=True)
    HELD = replace(ACTIVE, screen_held=True, sleep_held=True)

    def test_holds_both_while_looking(self):
        d = decide(T0, sensor(), False, self.BOTH, ACTIVE)
        self.assertEqual(d.actions, ["screen:hold", "sleep:hold"])
        self.assertEqual(decide(T0 + 1, sensor(), False, self.BOTH, d.memory).actions, [])

    def test_options_are_independent(self):
        sleep_only = decide(T0, sensor(), False, replace(CFG, prevent_sleep=True), ACTIVE)
        self.assertEqual(sleep_only.actions, ["sleep:hold"])
        screen_only = decide(T0, sensor(), False, replace(CFG, keep_screen_on=True), ACTIVE)
        self.assertEqual(screen_only.actions, ["screen:hold"])
        self.assertEqual(decide(T0, sensor(), False, CFG, ACTIVE).actions, [])

    def test_turning_one_off_releases_only_it(self):
        d = decide(T0, sensor(), False, replace(self.BOTH, prevent_sleep=False), self.HELD)
        self.assertEqual(d.actions, ["sleep:release"])

    def test_grace_after_looking_away_then_release(self):
        s = sensor(attention=False, looking_away_since=T0)
        d = decide(T0 + 5, s, False, self.BOTH, self.HELD)
        self.assertEqual(d.actions, [])
        self.assertEqual(d.wake_at, T0 + 10)   # the dim comes first
        d = decide(T0 + agent.LOOK_GRACE, s, False, self.BOTH, replace(self.HELD, dimmed=True))
        self.assertEqual(d.actions, ["screen:release", "sleep:release"])

    def test_released_when_leaving_or_locked(self):
        away = sensor(present=False, attention=False, away_since=T0, looking_away_since=T0)
        for d in (decide(T0 + 1, away, False, self.BOTH, self.HELD),
                  decide(T0, sensor(), True, self.BOTH, self.HELD)):
            self.assertIn("screen:release", d.actions)
            self.assertIn("sleep:release", d.actions)

    def test_released_when_sensor_not_ready_or_disabled(self):
        for d in (decide(T0, Sensor(), False, self.BOTH, self.HELD),
                  decide(T0, sensor(), False, replace(self.BOTH, enabled=False), self.HELD)):
            self.assertIn("screen:release", d.actions)
            self.assertIn("sleep:release", d.actions)


class DisabledTests(unittest.TestCase):
    def test_disabled_releases_everything(self):
        d = decide(T0, sensor(attention=False, looking_away_since=0), False,
                   replace(CFG, enabled=False), replace(ACTIVE, dimmed=True))
        self.assertEqual(d.actions, ["restore", "sensor:standby"])
        self.assertIsNone(d.wake_at)


class ConfigTests(unittest.TestCase):
    def load(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(text)
        try:
            return agent.load_config(f.name, log=lambda m: None)
        finally:
            os.unlink(f.name)

    def test_defaults_when_missing(self):
        self.assertEqual(agent.load_config("/nonexistent", log=lambda m: None), Config())

    def test_values_clamped(self):
        c = self.load("[presence]\nlock_after = 1\ndim_level = 500\ndim_after = 30\n")
        self.assertEqual((c.lock_after, c.dim_level, c.dim_after), (10, 90, 30))

    def test_garbage_keeps_defaults(self):
        c = self.load("[presence]\nlock = maybe\nlock_after = soon\n")
        self.assertEqual((c.lock, c.lock_after), (Config().lock, Config().lock_after))

    def test_sample_rate(self):
        self.assertEqual(self.load("[presence]\nsample_rate = 5\n").sample_rate, 5.0)
        self.assertEqual(self.load("[presence]\nsample_rate = 50\n").sample_rate, 10.0)
        self.assertEqual(self.load("[presence]\nsample_rate = 0.1\n").sample_rate, 0.5)
        self.assertEqual(self.load("[presence]\nsample_rate = nan\n").sample_rate, Config().sample_rate)
        self.assertEqual(self.load("[presence]\nsample_rate = quick\n").sample_rate, Config().sample_rate)


if __name__ == "__main__":
    unittest.main()
