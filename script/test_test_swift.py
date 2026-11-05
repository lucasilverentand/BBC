"""Regression checks for the test runner's false-green safeguards."""
from pathlib import Path
import importlib.util
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("test_swift", Path(__file__).with_name("test_swift.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_summaries_require_positive_execution_count(self):
        for output in ["Build complete!", "Executed 0 tests, with 0 failures", "Test run with 0 tests passed after 0.001 seconds."]:
            self.assertFalse(runner.executed_tests(output), output)
        for output in ["Executed 1 test, with 0 failures", "Executed 42 tests, with 0 failures", "✔ Test run with 3 tests passed after 0.010 seconds.", "Executed 19 tests, with 0 failures\nTest run with 0 tests in 0 suites passed"]:
            self.assertTrue(runner.executed_tests(output), output)

    def test_linux_zero_tests_fails_without_invoking_xcrun(self):
        with patch.object(runner.sys, "argv", ["test_swift.py"]), patch.object(runner.sys, "platform", "linux"), patch.object(runner, "stream", return_value="Executed 0 tests") as stream:
            with self.assertRaisesRegex(SystemExit, "executed no tests"):
                runner.main()
            self.assertEqual(stream.call_count, 1)

    def test_macos_fallback_checks_actual_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "FixturePackageTests.xctest"
            bundle.mkdir()
            with patch.object(runner.sys, "argv", ["test_swift.py"]), patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output", return_value=directory + "\n"), patch.object(runner, "stream", side_effect=["Executed 0 tests", "Executed 0 tests"]) as stream:
                with self.assertRaisesRegex(SystemExit, "bundle executed no tests"):
                    runner.main()
                self.assertEqual(stream.call_args.args[0], ["xcrun", "xctest", str(bundle)])

    def test_macos_fallback_accepts_executed_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "FixturePackageTests.xctest").mkdir()
            with patch.object(runner.sys, "argv", ["test_swift.py"]), patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output", return_value=directory + "\n"), patch.object(runner, "stream", side_effect=["Executed 0 tests", "Executed 2 tests"]):
                runner.main()

    def test_min_tests_floor_fails_below_and_passes_at_floor(self):
        with patch.object(runner.sys, "platform", "linux"), patch.object(runner, "stream", return_value="Executed 10 tests, with 0 failures"):
            with self.assertRaisesRegex(SystemExit, "executed 10 tests; expected at least 11"):
                runner.main(["--min-tests", "11"])
            runner.main(["--min-tests", "10"])

    def test_macos_fallback_enforces_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "FixturePackageTests.xctest").mkdir()
            with patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output", return_value=directory + "\n"), patch.object(runner, "stream", side_effect=["Build complete!", "Executed 3 tests"]):
                with self.assertRaisesRegex(SystemExit, "executed 3 tests; expected at least 5"):
                    runner.main(["--min-tests", "5"])
            with patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output", return_value=directory + "\n"), patch.object(runner, "stream", side_effect=["Build complete!", "Executed 5 tests"]):
                runner.main(["--min-tests", "5"])

    def test_fallback_without_bundle_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output", return_value=directory + "\n"), patch.object(runner, "stream", return_value="Build complete!"):
                with self.assertRaisesRegex(SystemExit, "no XCTest bundle"):
                    runner.main([])

    def test_current_output_success_does_not_fall_back(self):
        with patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output") as build, patch.object(runner, "stream", return_value="Executed 4 tests") as stream:
            runner.main(["--min-tests", "4"])
            self.assertEqual(stream.call_count, 1)
            build.assert_not_called()

    def test_release_fallback_resolves_only_the_release_output(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "ReleasePackageTests.xctest"
            bundle.mkdir()
            with patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "build_output", return_value=directory) as build, patch.object(runner, "stream", side_effect=["Build complete!", "Executed 5 tests"]) as stream:
                runner.main(["--configuration", "release", "--min-tests", "5"])
                for command in [stream.call_args_list[0].args[0], build.call_args.args[0]]:
                    self.assertEqual(command[command.index("--configuration") + 1], "release")
                self.assertEqual(stream.call_args_list[1].args[0], ["xcrun", "xctest", str(bundle)])


class StreamTests(unittest.TestCase):
    def run_stream(self, code, timeout=None):
        environment = os.environ.copy()
        if timeout is not None:
            environment["BBC_TEST_TIMEOUT_SECONDS"] = str(timeout)
        return runner.stream([sys.executable, "-c", code], environment)

    def test_nonzero_exit_fails_despite_positive_output(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_stream("print('Executed 50 tests, with 0 failures'); raise SystemExit(3)")
        self.assertEqual(raised.exception.code, 3)

    def test_zero_exit_returns_output(self):
        self.assertIn("Executed 2 tests", self.run_stream("print('Executed 2 tests')"))

    def test_timeout_terminates_owned_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "survived"
            child_code = f"import time,pathlib; time.sleep(2.5); pathlib.Path({str(marker)!r}).touch()"
            code = ("import subprocess,sys,time\n"
                    f"subprocess.Popen([sys.executable,'-c',{child_code!r}])\n"
                    "time.sleep(60)")
            with self.assertRaisesRegex(SystemExit, "timed out after 1 seconds"):
                self.run_stream(code, timeout=1)
            import time; time.sleep(1)
            self.assertFalse(marker.exists(), "grandchild survived timeout")

    def test_timeout_kills_descendant_even_if_leader_exits_on_term(self):
        import time
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "survived"
            child = ("import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"time.sleep(3); pathlib.Path({str(marker)!r}).touch()")
            code = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(60)"
            started = time.monotonic()
            with self.assertRaisesRegex(SystemExit, "timed out"):
                self.run_stream(code, timeout=0.5)
            self.assertLess(time.monotonic() - started, 5)
            time.sleep(2)
            self.assertFalse(marker.exists(), "descendant ignored TERM and survived the leader")

    def test_invalid_timeout_is_rejected(self):
        for value in ["0", "-1", "abc", "nan", "inf"]:
            with self.assertRaisesRegex(SystemExit, "BBC_TEST_TIMEOUT_SECONDS"):
                self.run_stream("pass", timeout=value)

    def test_macos_partial_execution_fails_without_rerunning(self):
        with patch.object(runner.sys, "platform", "darwin"), patch.object(runner, "stream", return_value="Executed 2 tests") as stream:
            with self.assertRaisesRegex(SystemExit, "expected at least 3"):
                runner.main(["--min-tests", "3"])
            self.assertEqual(stream.call_count, 1)

    def test_overall_deadline_applies_to_build_path_lookup(self):
        import time
        environment = os.environ.copy()
        environment["_BBC_TEST_DEADLINE"] = str(time.monotonic() + 0.2)
        with self.assertRaisesRegex(SystemExit, "timed out"):
            runner.build_output([sys.executable, "-c", "import time; time.sleep(60)"], environment)

    def test_log_captures_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "logs" / "out.log"
            with patch.object(runner, "stream", side_effect=lambda c, e, log=None: (log.write("captured\n"), "Executed 1 test")[1]):
                runner.main(["--log", str(path)])
            self.assertEqual(path.read_text(), "captured\n")


if __name__ == "__main__":
    unittest.main()
