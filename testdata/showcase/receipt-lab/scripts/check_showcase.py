#!/usr/bin/env python3
import json
import pathlib
import sys


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    config_path = root / "zask.json"
    with config_path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)

    service_count = sum(len(group["services"]) for group in config["groups"])
    required = [
        root / "scripts" / "service.py",
        root / "infra" / "compose.yaml",
    ]
    missing = [str(path.relative_to(root)) for path in required if not path.exists()]
    if missing:
        print("missing showcase files: " + ", ".join(missing), file=sys.stderr)
        return 1

    print(f"receipt-lab precheck ok: {service_count} services")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
