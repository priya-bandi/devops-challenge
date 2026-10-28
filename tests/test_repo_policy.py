"""Release-policy checks that run in CI before any image is built."""
import os
import re
import unittest

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel_path):
    with open(os.path.join(BASE, rel_path), "r", encoding="utf-8") as f:
        return f.read()


class TestRepoPolicy(unittest.TestCase):
    def test_compose_has_no_hardcoded_secrets(self):
        compose = read("docker-compose.yml")
        pattern = re.compile(r"^\s*([A-Z_]*(PASSWORD|SECRET|TOKEN|ACCESS_KEY)[A-Z_]*)\s*:\s*(\S+)", re.M)
        for name, _, value in pattern.findall(compose):
            self.assertTrue(value.strip("\"'").startswith("${"),
                            f"{name} must come from .env, not be hardcoded")

    def test_no_mutable_latest_tag(self):
        for rel in ("docker-compose.yml", ".github/workflows/ci.yml"):
            self.assertNotRegex(read(rel), r":latest\b", f"{rel} uses a mutable :latest tag")

    def test_dockerfile_runs_as_non_root(self):
        users = re.findall(r"^USER\s+(\S+)", read("Dockerfile"), re.M)
        self.assertTrue(users, "Dockerfile has no USER instruction")
        self.assertNotIn(users[-1].split(":")[0], ("root", "0"))

    def test_env_example_present_and_env_ignored(self):
        self.assertTrue(os.path.exists(os.path.join(BASE, ".env.example")))
        self.assertIn(".env", read(".gitignore").splitlines())


if __name__ == "__main__":
    unittest.main()
