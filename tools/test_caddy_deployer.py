import contextlib
import io
import tempfile
import unittest
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "tools" / "caddy_deployer.py"
SPEC = spec_from_file_location("caddy_deployer", MODULE_PATH)
caddy_deployer = module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(caddy_deployer)


class CaddyDeployerTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.home_dir = Path(self.temp_dir.name)
        self.home_patch = mock.patch.object(caddy_deployer.Path, "home", return_value=self.home_dir)
        self.logging_patch = mock.patch.object(
            caddy_deployer.CaddyDeployer,
            "_setup_logging",
            lambda instance: setattr(instance, "logger", mock.Mock())
        )
        self.home_patch.start()
        self.logging_patch.start()

    def tearDown(self):
        self.logging_patch.stop()
        self.home_patch.stop()
        self.temp_dir.cleanup()

    def make_deployer(self) -> "caddy_deployer.CaddyDeployer":
        deployer = caddy_deployer.CaddyDeployer()
        deployer.system = "linux"
        deployer.caddy_path = Path("/usr/bin/caddy")
        return deployer

    def test_generate_config_without_ssl_uses_http_and_no_hsts(self):
        deployer = self.make_deployer()

        self.assertTrue(
            deployer.generate_config(domain="example.com", backend_port=8080, enable_ssl=False)
        )

        content = deployer.config_file.read_text(encoding="utf-8")
        self.assertIn("http://example.com {", content)
        self.assertNotIn("Strict-Transport-Security", content)
        self.assertNotIn("tls internal", content)

    def test_generate_config_with_local_ssl_uses_https_and_internal_tls(self):
        deployer = self.make_deployer()

        self.assertTrue(
            deployer.generate_config(domain="localhost", backend_port=8080, enable_ssl=True)
        )

        content = deployer.config_file.read_text(encoding="utf-8")
        self.assertIn("https://localhost {", content)
        self.assertIn("Strict-Transport-Security", content)
        self.assertIn("tls internal", content)

    def test_generate_config_with_custom_config_ignores_port_and_ssl(self):
        deployer = self.make_deployer()
        custom_config = ':9000 { respond "ok" }'

        self.assertTrue(
            deployer.generate_config(
                domain="example.com",
                backend_port=None,
                enable_ssl=True,
                custom_config=custom_config
            )
        )

        self.assertEqual(custom_config, deployer.config_file.read_text(encoding="utf-8"))

    def test_stale_pid_file_is_not_treated_as_running(self):
        deployer = self.make_deployer()
        deployer.pid_file.write_text("4242", encoding="utf-8")

        with mock.patch.object(
            deployer,
            "_get_process_info",
            return_value={
                "pid": "4242",
                "name": "python",
                "executable_path": "/usr/bin/python3",
                "command_line": "python service.py",
            },
        ):
            self.assertFalse(deployer._check_pid_file_process())
            self.assertFalse(deployer.is_running())
            self.assertFalse(deployer.status()["running"])

        self.assertFalse(deployer.pid_file.exists())

    def test_undeploy_does_not_kill_unmanaged_pid(self):
        deployer = self.make_deployer()
        deployer.pid_file.write_text("5151", encoding="utf-8")

        with mock.patch.object(
            deployer,
            "_get_process_info",
            return_value={
                "pid": "5151",
                "name": "python",
                "executable_path": "/usr/bin/python3",
                "command_line": "python worker.py",
            },
        ), mock.patch.object(deployer, "_terminate_process") as terminate_process:
            self.assertTrue(deployer.undeploy())
            terminate_process.assert_not_called()

        self.assertFalse(deployer.pid_file.exists())

    def test_extract_frontend_and_https_endpoints_preserve_scheme(self):
        deployer = self.make_deployer()
        deployer.config_file.write_text(
            "https://localhost {\n    reverse_proxy 127.0.0.1:8080\n    tls internal\n}\n",
            encoding="utf-8",
        )

        self.assertEqual(["https://localhost"], deployer._extract_frontend_endpoints())
        self.assertEqual(["https://localhost"], deployer._extract_https_endpoints())
        self.assertEqual([443], deployer._extract_listening_ports())

    def test_deploy_fails_when_unmanaged_process_owns_required_ports(self):
        deployer = self.make_deployer()

        with mock.patch.object(
            deployer,
            "_check_port_conflicts",
            return_value={"admin_port": "PID 99 (caddy)", "listening_ports": []},
        ), mock.patch.object(
            deployer,
            "_get_managed_pid",
            return_value=None,
        ), mock.patch.object(
            deployer,
            "_get_running_caddy_processes",
            return_value=[{"pid": "99", "name": "caddy", "command_line": "caddy run --config /tmp/other", "managed": False}],
        ):
            self.assertFalse(deployer.deploy())


class ParserTests(unittest.TestCase):
    def test_config_only_deploy_args_are_valid(self):
        parser, deploy_parser = caddy_deployer.build_parser()
        args = parser.parse_args(["deploy", "--config", "custom_caddyfile.txt"])

        caddy_deployer.validate_deploy_args(args, deploy_parser)
        self.assertIsNone(args.port)
        self.assertEqual("custom_caddyfile.txt", args.config)

    def test_missing_port_without_config_is_rejected(self):
        parser, deploy_parser = caddy_deployer.build_parser()
        args = parser.parse_args(["deploy", "--domain", "example.com"])

        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                caddy_deployer.validate_deploy_args(args, deploy_parser)


if __name__ == "__main__":
    unittest.main()
