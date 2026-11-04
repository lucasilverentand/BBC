"""Regression checks for the test runner's false-green safeguards."""
from pathlib import Path
import importlib.util
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
            with patch.object(runner.sys, "argv", ["test_swift.py"]), patch.object(runner.sys, "platform", "darwin"), patch.object(runner.subprocess, "check_output", return_value=directory + "\n"), patch.object(runner, "stream", side_effect=["Executed 0 tests", "Executed 0 tests"]) as stream:
                with self.assertRaisesRegex(SystemExit, "bundle executed no tests"):
                    runner.main()
                self.assertEqual(stream.call_args.args[0], ["xcrun", "xctest", str(bundle)])

    def test_macos_fallback_accepts_executed_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "FixturePackageTests.xctest").mkdir()
            with patch.object(runner.sys, "argv", ["test_swift.py"]), patch.object(runner.sys, "platform", "darwin"), patch.object(runner.subprocess, "check_output", return_value=directory + "\n"), patch.object(runner, "stream", side_effect=["Executed 0 tests", "Executed 2 tests"]):
                runner.main()


if __name__ == "__main__":
    unittest.main()
