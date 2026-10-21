"""Tests for the resumable, verified model downloader spike (FEAT-001 T003).

Run: uv run --no-project python -m unittest -v spikes/model-download/test_download.py
"""
import hashlib
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import download  # noqa: E402

BLOB = os.urandom(3 * 1024 * 1024 + 123)
BLOB_SHA = hashlib.sha256(BLOB).hexdigest()


class Behaviour:
    """Mutable switches shared by one test server."""

    def __init__(self):
        self.support_range = True
        self.corrupt_requests = 0  # corrupt the body of the first N requests
        self.requests = []  # (path, range header)


def make_handler(behaviour):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            rng = self.headers.get("Range")
            behaviour.requests.append((self.path, rng))
            if self.path.startswith("/redirect/"):
                self.send_response(302)
                self.send_header("Location", "/files/" + self.path.split("/", 2)[2])
                self.end_headers()
                return
            body = BLOB
            if behaviour.corrupt_requests > 0:
                behaviour.corrupt_requests -= 1
                body = bytes([BLOB[0] ^ 0xFF]) + BLOB[1:]
            start = 0
            if rng and behaviour.support_range:
                start = int(rng.split("=")[1].split("-")[0])
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{len(body) - 1}/{len(body)}")
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(body) - start))
            self.send_header("Accept-Ranges", "bytes" if behaviour.support_range else "none")
            self.end_headers()
            try:
                self.wfile.write(body[start:])
            except (BrokenPipeError, ConnectionResetError):
                pass

    return Handler


class Server:
    def __init__(self):
        self.behaviour = Behaviour()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.behaviour))
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def entry(sha=BLOB_SHA):
    return {"path": "sub/model.bin", "size": len(BLOB), "sha256": sha}


class DownloaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dest = Path(self.tmp.name)
        self.a = Server()
        self.b = Server()

    def tearDown(self):
        self.a.close()
        self.b.close()
        self.tmp.cleanup()

    def url(self, server, prefix="files"):
        return lambda path: f"{server.base}/{prefix}/{path}"

    def target(self):
        return self.dest / "sub" / "model.bin"

    def test_fresh_download_is_verified_and_atomic(self):
        result = download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        self.assertEqual(result["how"], "fresh")
        self.assertEqual(self.target().read_bytes(), BLOB)
        self.assertFalse(self.target().with_name("model.bin.part").exists())

    def test_cached_file_is_not_downloaded_again(self):
        download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        n = len(self.a.behaviour.requests)
        result = download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        self.assertEqual(result["how"], "cached")
        self.assertEqual(len(self.a.behaviour.requests), n)

    def test_interrupted_download_resumes_with_range(self):
        with self.assertRaises(download.Interrupted):
            download.download_file(entry(), self.dest, [("a", self.url(self.a))], interrupt_after=1024 * 1024)
        part = self.target().with_name("model.bin.part")
        self.assertGreaterEqual(part.stat().st_size, 1024 * 1024)
        result = download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        self.assertEqual(result["how"], "resumed")
        self.assertEqual(self.target().read_bytes(), BLOB)
        self.assertTrue(self.a.behaviour.requests[-1][1].startswith("bytes="))

    def test_range_header_survives_redirect(self):
        with self.assertRaises(download.Interrupted):
            download.download_file(entry(), self.dest, [("a", self.url(self.a, "redirect"))], interrupt_after=1024 * 1024)
        result = download.download_file(entry(), self.dest, [("a", self.url(self.a, "redirect"))])
        self.assertEqual(result["how"], "resumed")
        self.assertEqual(self.target().read_bytes(), BLOB)

    def test_server_ignoring_range_restarts_from_zero(self):
        with self.assertRaises(download.Interrupted):
            download.download_file(entry(), self.dest, [("a", self.url(self.a))], interrupt_after=1024 * 1024)
        self.a.behaviour.support_range = False
        result = download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        self.assertEqual(result["how"], "restarted")
        self.assertEqual(self.target().read_bytes(), BLOB)

    def test_checksum_mismatch_redownloads_once(self):
        self.a.behaviour.corrupt_requests = 1
        result = download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        self.assertEqual(result["checksum_retries"], 1)
        self.assertEqual(self.target().read_bytes(), BLOB)

    def test_checksum_mismatch_twice_fails_and_leaves_no_file(self):
        self.a.behaviour.corrupt_requests = 2
        with self.assertRaises(download.DownloadError):
            download.download_file(entry(), self.dest, [("a", self.url(self.a))])
        self.assertFalse(self.target().exists())
        self.assertFalse(self.target().with_name("model.bin.part").exists())

    def test_unreachable_source_falls_back_to_next(self):
        dead = lambda path: "http://127.0.0.1:9/files/" + path  # port 9 (discard) is closed
        result = download.download_file(entry(), self.dest, [("dead", dead), ("b", self.url(self.b))])
        self.assertEqual(result["source"], "b")
        self.assertEqual(self.target().read_bytes(), BLOB)

    def test_interrupted_download_can_resume_from_another_source(self):
        with self.assertRaises(download.Interrupted):
            download.download_file(entry(), self.dest, [("a", self.url(self.a))], interrupt_after=1024 * 1024)
        result = download.download_file(entry(), self.dest, [("b", self.url(self.b))])
        self.assertEqual((result["how"], result["source"]), ("resumed", "b"))
        self.assertEqual(self.target().read_bytes(), BLOB)

    def test_unknown_checksum_is_computed_and_reported(self):
        result = download.download_file(entry(sha=None), self.dest, [("a", self.url(self.a))])
        self.assertEqual(result["sha256"], BLOB_SHA)
        self.assertEqual(result["sha256_verified"], False)


if __name__ == "__main__":
    unittest.main()
