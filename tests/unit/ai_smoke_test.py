import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("smoke", ROOT / "tests/lib/smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class FakeClient:
    def __init__(self, page, status=200):
        self.page, self.status = page, status

    def request(self, *args):
        return self.status, "", self.page


class AISmokeTest(unittest.TestCase):
    def test_persisted_assistant_reply_passes(self):
        page = '<div id="assistant_message_123"><div><div class="prose prose--ai-chat"><p>SURE_TEST</p></div></div></div>'
        smoke.wait_for_ai_reply(FakeClient(page), "/chats/test", "SURE_TEST", timeout=0)

    def test_echoed_prompt_and_pending_assistant_do_not_pass(self):
        page = '<div id="user_message_123">SURE_TEST</div><div id="assistant_message_123"><div data-chat-target="pendingResponse">Thinking…</div></div>'
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            smoke.wait_for_ai_reply(FakeClient(page), "/chats/test", "SURE_TEST", timeout=0)

    def test_unrelated_prose_and_old_answer_do_not_pass(self):
        page = '<div class="prose--ai-chat">SURE_TEST</div><div id="assistant_message_123"><div class="prose--ai-chat">OLD_REPLY</div></div>'
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            smoke.wait_for_ai_reply(FakeClient(page), "/chats/test", "SURE_TEST", timeout=0)

    def test_followup_cannot_pass_with_old_answer(self):
        page = '<div id="assistant_message_123"><div class="prose--ai-chat">42.17</div></div>'
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            smoke.wait_for_ai_reply(FakeClient(page), "/chats/test", "42.17", timeout=0, min_replies=2)

    def test_http_error_fails_without_printing_provider_body(self):
        with contextlib.redirect_stdout(io.StringIO()) as output, self.assertRaises(SystemExit):
            smoke.wait_for_ai_reply(FakeClient("sensitive-provider-body", 500), "/chats/test", "SURE_TEST", timeout=0)
        self.assertNotIn("sensitive-provider-body", output.getvalue())

    def test_persistent_entry_requires_explicit_data_authorization(self):
        env = {**os.environ, "E2E_SAMPLE_URL": "https://example.com"}
        env.pop("E2E_CONFIRM_SAMPLE_DATA", None)
        result = subprocess.run([str(ROOT / "tests/render/persistent-smoke.sh")], env=env, capture_output=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b"E2E_CONFIRM_SAMPLE_DATA", result.stderr)

    def test_persistent_entry_rejects_credentials_or_non_https(self):
        for url in ("http://example.com", "https://key@example.com", "https://example.com/path"):
            env = {**os.environ, "E2E_SAMPLE_URL": url, "E2E_CONFIRM_SAMPLE_DATA": "yes", "E2E_ADMIN_ESTABLISHED": "yes"}
            result = subprocess.run([str(ROOT / "tests/render/persistent-smoke.sh")], env=env, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn(b"plain HTTPS origin", result.stderr)


class ImageIdentityTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("identity", ROOT / "tests/render/verify-live-image.py")
        self.identity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.identity)
        self.digest = "sha256:" + "a" * 64
        self.service = {"id": "srv-web", "type": "web_service", "ownerId": "tea-test", "environmentId": "evm-test", "serviceDetails": {"url": "https://sample.onrender.com"}}
        self.deploys = [{"deploy": {"id": "dep-test", "status": "live", "image": {"sha": self.digest}}}]

    def verify(self):
        return self.identity.validate_service(self.service, self.deploys, kind="web_service", owner="tea-test", environment="evm-test", digest=self.digest, url="https://sample.onrender.com")

    def test_matching_live_deploy_passes(self):
        self.assertEqual("dep-test", self.verify()["deploy"])

    def test_configured_tag_does_not_substitute_for_live_digest(self):
        self.deploys[0]["deploy"]["image"] = {"ref": "ghcr.io/we-promise/sure:stable"}
        with self.assertRaises(ValueError):
            self.verify()

    def test_wrong_digest_fails(self):
        self.deploys[0]["deploy"]["image"]["sha"] = "sha256:" + "b" * 64
        with self.assertRaises(ValueError):
            self.verify()

    def test_wrong_environment_fails(self):
        self.service["environmentId"] = "evm-demo"
        with self.assertRaises(ValueError):
            self.verify()

    def test_non_live_deploy_fails(self):
        self.deploys[0]["deploy"]["status"] = "build_in_progress"
        with self.assertRaises(ValueError):
            self.verify()


if __name__ == "__main__":
    unittest.main()
