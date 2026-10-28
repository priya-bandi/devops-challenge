"""Container healthcheck probe (no curl/wget needed in the slim image).

Usage: python healthcheck.py <url> [accepted_status ...]
Exits 0 only if the URL answers with one of the accepted HTTP status codes
(default: 200). Any error, timeout or other status exits 1.
"""
import sys
import urllib.error
import urllib.request


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: healthcheck.py <url> [accepted_status ...]", file=sys.stderr)
        return 1
    url = sys.argv[1]
    accepted = {int(code) for code in sys.argv[2:]} or {200}
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            status = resp.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception as exc:  # connection refused, timeout, DNS failure
        print(f"healthcheck: {url} unreachable: {exc}", file=sys.stderr)
        return 1
    if status in accepted:
        return 0
    print(f"healthcheck: {url} returned {status}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
