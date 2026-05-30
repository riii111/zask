# Receipt Lab Showcase

Receipt Lab is a fictional receipt processing platform for zask demos,
screenshots, and local behavior checks. It uses only Python standard library
processes for the default zask workflow.

```text
browser
  |
  v
web-console
  |
  v
bff-dashboard
  |-----------|-----------|
  v           v           v
api-core  api-files   realtime
  |           |           |
  v           v           v
postgres  object-store  redis
  ^
  |
ocr-worker     email-worker     scheduler
  |                 |                |
  v                 v                v
receipts.pending   inbox.new        jobs.delayed
```

The Docker Compose file models shared infrastructure and log-heavy background
containers. The default startup order leaves Docker stopped. Use the normal
zask workspace for screenshots, and start Docker explicitly when the local
machine can build or pull the images.

Useful commands:

```sh
cd /path/to/zask
zig build run -- --config testdata/showcase/receipt-lab/zask.json list
zig build run -- --config testdata/showcase/receipt-lab/zask.json open --dashboard
zig build run -- --config testdata/showcase/receipt-lab/zask.json start docker
zig build run -- --config testdata/showcase/receipt-lab/zask.json status
zig build run -- --config testdata/showcase/receipt-lab/zask.json close
```
