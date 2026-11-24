#!/usr/bin/env python3
"""Test-only OpenAI-compatible endpoint for the local e2e (never deployed).

Simple AI keeps its OpenAI settings out of the Blueprint (Render environment
groups supply them), so the local e2e runs this stub and points sure-web and
sure-worker at it. It serves just enough of the API for Sure's built-in
assistant path:

  GET  /healthz               unauthenticated liveness for the compose healthcheck
  GET  /v1/models             the configured model
  POST /v1/chat/completions   a deterministic reply naming the requested model
  POST /v1/embeddings         a zero vector of the configured dimension

Every /v1 call requires `Authorization: Bearer $STUB_TOKEN`, so a service
wired to the wrong token fails the way it would against a real provider.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["STUB_TOKEN"]
MODEL = os.environ.get("STUB_MODEL", "e2e-test-model")
PORT = int(os.environ.get("PORT", "8100"))
DIMENSIONS = int(os.environ.get("EMBEDDING_DIMENSIONS", "1536"))


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"status": "ok"})
        elif not self.authorized():
            self.send_json(401, {"error": {"message": "Incorrect API key", "type": "invalid_request_error"}})
        elif self.path == "/v1/models":
            self.send_json(200, {"object": "list", "data": [
                {"id": MODEL, "object": "model", "created": 0, "owned_by": "e2e"}]})
        else:
            self.send_json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self):
        if not self.authorized():
            self.send_json(401, {"error": {"message": "Incorrect API key", "type": "invalid_request_error"}})
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"error": {"message": "invalid JSON", "type": "invalid_request_error"}})
            return
        if self.path == "/v1/chat/completions":
            model = body.get("model", MODEL)
            self.send_json(200, {
                "id": "chatcmpl-e2e",
                "object": "chat.completion",
                "created": 0,
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": f"pong from {model}"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 1, "completion_tokens": 4, "total_tokens": 5},
            })
        elif self.path == "/v1/embeddings":
            self.send_json(200, {
                "object": "list",
                "data": [{"object": "embedding", "embedding": [0.0] * DIMENSIONS, "index": 0}],
                "model": body.get("model", MODEL),
                "usage": {"prompt_tokens": 1, "total_tokens": 1},
            })
        else:
            self.send_json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
