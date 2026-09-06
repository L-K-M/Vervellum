#!/usr/bin/env python3
"""Exercise the real CLI, transport, and pipeline using loopback-only providers."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from enum import Enum, auto
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BINARY = Path(sys.argv.pop(1)).resolve()
FAKE_KEY = "fixture-credential-never-log"
PROVIDER_ERROR = "untrusted-provider-error-" + FAKE_KEY
JSON_TYPE = "application/json"
SSE_TYPE = "text/event-stream"
CONTEXT_BUDGET = 110_000
CLI_TIMEOUT = 20


class Scenario(Enum):
    VALID = auto()
    RETRY = auto()
    REJECT = auto()
    EOF = auto()
    MALFORMED = auto()
    STREAM_ERROR = auto()
    WHOLE_RESPONSE = auto()
    ASSESSMENT_FAILURE = auto()
    REDIRECT = auto()


class Fixture:
    def __init__(self):
        self.scenario = Scenario.VALID
        self.requests = []
        self.accepted_json_calls = 0

    @staticmethod
    def json_response(value, status=HTTPStatus.OK):
        return status, JSON_TYPE, json.dumps(value).encode()

    @staticmethod
    def completion(content):
        return {"choices": [{"message": {"content": content}, "finish_reason": "stop"}]}

    def respond(self, path, headers, body):
        self.requests.append((path, dict(headers), body))
        if path == "/mcp":
            return self.mcp(body)

        if self.scenario == Scenario.REDIRECT:
            return HTTPStatus.TEMPORARY_REDIRECT, JSON_TYPE, b""
        if self.scenario == Scenario.REJECT or (
            self.scenario == Scenario.RETRY and "temperature" in body
        ):
            return self.json_response({"error": PROVIDER_ERROR}, HTTPStatus.BAD_REQUEST)
        if body.get("stream"):
            return self.answer()

        self.accepted_json_calls += 1
        if self.accepted_json_calls == 1:
            plan = {"reading": "Check fixture evidence.", "searches": [
                {"purpose": "Verify", "arguments": {"query": "fixture evidence"}}
            ]}
            return self.json_response(self.completion(json.dumps(plan)))
        if self.scenario == Scenario.ASSESSMENT_FAILURE:
            return self.json_response({"error": PROVIDER_ERROR}, HTTPStatus.INTERNAL_SERVER_ERROR)
        assessment = {"findings": [{"claim": "Fixture fact", "verdict": "supported",
                                     "reasoning": "Retrieved evidence", "sources": [1]}],
                      "limitations": "Search summaries only", "followups": []}
        return self.json_response(self.completion(json.dumps(assessment)))

    def mcp(self, body):
        method = body["method"]
        if method == "notifications/initialized":
            return HTTPStatus.ACCEPTED, JSON_TYPE, b""
        if method == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "web_search", "inputSchema": {
                "type": "object", "properties": {"query": {"type": "string"}},
                "required": ["query"]}}]}
        else:
            results = {"results": [{"url": "https://retrieved.example/fact", "title": "Fixture source",
                                    "content": "Fixture fact is supported by retrieved evidence."}]}
            result = {"content": [{"type": "text", "text": json.dumps(results)}]}
        return self.json_response({"jsonrpc": "2.0", "id": body["id"], "result": result})

    def answer(self):
        answer = "Fixture fact [1]."
        if self.scenario == Scenario.WHOLE_RESPONSE:
            return self.json_response(self.completion(answer))
        delta = {"choices": [{"delta": {"content": answer}}]}
        payload = "data: " + json.dumps(delta) + "\r\n\r\n"
        if self.scenario == Scenario.EOF:
            return HTTPStatus.OK, SSE_TYPE, payload.encode()
        if self.scenario == Scenario.MALFORMED:
            payload += "data: {broken\r\n\r\n"
        if self.scenario == Scenario.STREAM_ERROR:
            payload += "data: " + json.dumps({"error": PROVIDER_ERROR}) + "\r\n\r\n"
        # No blank line before DONE: the assembler must retain this finish reason.
        payload += 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\r\ndata: [DONE]\r\n'
        return HTTPStatus.OK, SSE_TYPE, payload.encode()


class ProviderFixtures(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        fixture = self.fixture

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                status, content_type, payload = fixture.respond(self.path, self.headers, body)
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                if status == HTTPStatus.TEMPORARY_REDIRECT:
                    self.send_header("Location", "/redirect-target")
                self.end_headers()
                self.wfile.write(payload)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.worker = threading.Thread(target=self.server.serve_forever)
        self.worker.start()
        self.directory = tempfile.TemporaryDirectory(prefix="vervellum-providers-")
        root = Path(self.directory.name)
        config = root / "config" / "vervellum"
        config.mkdir(parents=True)
        endpoint = f"http://127.0.0.1:{self.server.server_port}"
        (config / "settings.json").write_text(json.dumps({
            "modelEndpoint": endpoint + "/v1", "modelName": "fixture",
            "searchEndpoint": endpoint + "/mcp", "historyEnabled": False,
        }))
        self.environment = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"),
                                XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
                                VERVELLUM_MODEL_KEY=FAKE_KEY, VERVELLUM_SEARCH_KEY=FAKE_KEY)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()
        self.directory.cleanup()

    def run_question(self, question="Verify fixture fact"):
        result = subprocess.run([str(BINARY), "--ask", question], env=self.environment,
                                text=True, capture_output=True, timeout=CLI_TIMEOUT)
        self.assertNotIn(FAKE_KEY, result.stdout + result.stderr)
        self.assertNotIn(PROVIDER_ERROR, result.stdout + result.stderr)
        return result

    def model_requests(self):
        return [entry for entry in self.fixture.requests if entry[0] == "/v1/chat/completions"]

    def test_complete_pipeline_and_per_call_accept(self):
        result = self.run_question()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Fixture fact [1].", result.stdout)
        self.assertIn("https://retrieved.example/fact", result.stdout)
        self.assertIn("supported", result.stdout.lower())
        requests = self.model_requests()
        self.assertEqual(len(requests), 3)
        for _, headers, body in requests:
            if body["stream"]:
                self.assertIn(SSE_TYPE, headers["Accept"])
            else:
                self.assertEqual(headers["Accept"], JSON_TYPE)
            self.assertEqual(headers["Authorization"], "Bearer " + FAKE_KEY)

    def test_optional_parameter_retry_is_once_and_remembered(self):
        self.fixture.scenario = Scenario.RETRY
        result = self.run_question()
        self.assertEqual(result.returncode, 0, result.stderr)
        requests = self.model_requests()
        self.assertEqual(len(requests), 4)
        self.assertIn("temperature", requests[0][2])
        for _, _, body in requests[1:]:
            self.assertNotIn("temperature", body)
            self.assertNotIn("response_format", body)

    def test_second_rejection_is_not_retried(self):
        self.fixture.scenario = Scenario.REJECT
        self.assertEqual(self.run_question().returncode, 1)
        self.assertEqual(len(self.model_requests()), 2)

    def assert_incomplete_stream(self, scenario):
        self.fixture.scenario = scenario
        result = self.run_question()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Fixture fact [1].", result.stdout)
        self.assertEqual(len(self.model_requests()), 2, "An incomplete answer must not be assessed or retried")

    def test_eof_without_finish_is_incomplete(self):
        self.assert_incomplete_stream(Scenario.EOF)

    def test_malformed_frames_cannot_disappear(self):
        self.assert_incomplete_stream(Scenario.MALFORMED)

    def test_stream_errors_do_not_duplicate_deltas(self):
        self.assert_incomplete_stream(Scenario.STREAM_ERROR)

    def test_whole_response_fallback_retains_completion(self):
        self.fixture.scenario = Scenario.WHOLE_RESPONSE
        result = self.run_question()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Fixture fact [1].", result.stdout)

    def test_assessment_failure_keeps_answer_and_warning(self):
        self.fixture.scenario = Scenario.ASSESSMENT_FAILURE
        result = self.run_question()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Fixture fact [1].", result.stdout)
        self.assertIn("assessment call failed", result.stdout)

    def test_redirect_is_not_followed(self):
        self.fixture.scenario = Scenario.REDIRECT
        self.assertEqual(self.run_question().returncode, 1)
        self.assertNotIn("/redirect-target", [entry[0] for entry in self.fixture.requests])

    def test_oversized_context_never_reaches_model(self):
        result = self.run_question("x" * CONTEXT_BUDGET)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.model_requests(), [])


if __name__ == "__main__":
    unittest.main()
