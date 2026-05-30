#!/usr/bin/env python3
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def service_payload(args):
    return {
        "service": args.name,
        "role": args.role,
        "status": "ok",
        "upstreams": args.upstream,
    }


def run_http(args):
    payload = service_payload(args)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self.write_json(200, payload)
            elif self.path == "/api/summary":
                self.write_json(200, {
                    "receipts_today": 128,
                    "pending_review": 9,
                    "matched_payments": 117,
                    "service": args.name,
                })
            else:
                self.write_text(200, landing_page(args, payload))

        def log_message(self, fmt, *values):
            print(f"{args.name} access: {fmt % values}", flush=True)

        def write_json(self, status, body):
            data = json.dumps(body, indent=2).encode("utf-8")
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def write_text(self, status, body):
            data = body.encode("utf-8")
            self.send_response(status)
            self.send_header("content-type", "text/plain; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"{args.name} listening on http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print(f"{args.name} stopped", flush=True)


def landing_page(args, payload):
    upstreams = "\n".join(f"- {item}" for item in payload["upstreams"]) or "- none"
    return (
        f"Receipt Lab / {args.name}\n"
        f"role: {args.role}\n"
        f"health: /health\n"
        f"summary: /api/summary\n"
        f"upstreams:\n{upstreams}\n"
    )


def run_worker(args):
    i = 1
    print(f"{args.name} consuming {args.queue}", flush=True)
    try:
        while True:
            print(f"{args.name} processed {args.role} job #{i}", flush=True)
            i += 1
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print(f"{args.name} stopped", flush=True)


def parse_args():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    http = sub.add_parser("http")
    http.add_argument("--name", required=True)
    http.add_argument("--role", required=True)
    http.add_argument("--port", type=int, required=True)
    http.add_argument("--upstream", action="append", default=[])

    worker = sub.add_parser("worker")
    worker.add_argument("--name", required=True)
    worker.add_argument("--role", required=True)
    worker.add_argument("--queue", required=True)
    worker.add_argument("--interval", type=float, default=2.0)

    return parser.parse_args()


if __name__ == "__main__":
    options = parse_args()
    if options.mode == "http":
        run_http(options)
    else:
        run_worker(options)
