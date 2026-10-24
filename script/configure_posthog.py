#!/usr/bin/env python3
"""Bundle public PostHog client configuration without evaluating .env as code."""

import ipaddress
import os
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit


KEYS = ("POSTHOG_PROJECT_TOKEN", "POSTHOG_HOST")
ASSIGNMENT = re.compile(r"^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$")


class ConfigurationError(Exception):
    pass


def read_dotenv(path):
    """Read only relevant KEY=value entries; quotes are literal, never expanded."""
    if not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError):
        raise ConfigurationError("Cannot read the repository .env file.") from None

    values = {}
    for number, line in enumerate(lines, start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        assignment = ASSIGNMENT.fullmatch(line)
        if assignment is None or assignment[1] not in KEYS:
            continue
        key, value = assignment.groups()
        value = value.strip()
        if value.startswith(("'", '"')):
            end = value.find(value[0], 1)
            if end == -1 or (value[end + 1 :].strip() and not value[end + 1 :].strip().startswith("#")):
                raise ConfigurationError(f"Malformed quoted {key} on .env line {number}.")
            value = value[1:end]
        else:
            value = re.split(r"[ \t]+#", value, maxsplit=1)[0].rstrip()
        values[key] = value
    return values


def validate_configuration(values):
    for key in KEYS:
        if not isinstance(values.get(key), str) or not values[key]:
            raise ConfigurationError(
                f"{key} is required. Set it in the build environment or repository .env; "
                "see .env.example."
            )

    token = values["POSTHOG_PROJECT_TOKEN"]
    if re.fullmatch(r"phc_[A-Za-z0-9]+", token) is None:
        raise ConfigurationError(
            "POSTHOG_PROJECT_TOKEN must be a public phc_ project token. "
            "Personal or secret API keys must never be bundled."
        )

    host = values["POSTHOG_HOST"]
    try:
        parsed = urlsplit(host)
        hostname = parsed.hostname
        port = parsed.port
        valid = (
            parsed.scheme == "https"
            and hostname
            and not re.search(r"\s", host)
            and parsed.username is None
            and parsed.password is None
            and "?" not in host
            and "#" not in host
            and parsed.path in ("", "/")
            and (port is None or 1 <= port <= 65535)
        )
        if valid:
            try:
                ipaddress.ip_address(hostname)
            except ValueError:
                valid = len(hostname) <= 253 and all(
                    re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                    for label in hostname.rstrip(".").split(".")
                )
        if not valid:
            raise ValueError
    except ValueError:
        raise ConfigurationError(
            "POSTHOG_HOST must be an HTTPS origin without credentials, a path, query, or fragment."
        ) from None

    return {"POSTHOG_PROJECT_TOKEN": token, "POSTHOG_HOST": host.rstrip("/")}


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--distribution", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    values = read_dotenv(root / ".env")
    values.update({key: os.environ[key].strip() for key in KEYS if key in os.environ})
    values = validate_configuration(values)
    # Only the packaging build selects production; .env and runtime cannot promote it.
    values.update({"IN_PASSING_ANALYTICS_ENVIRONMENT": "production" if args.distribution else "development",
                   "IN_PASSING_ANALYTICS_INTERNAL": "false" if args.distribution else "true"})
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_bytes(plistlib.dumps(values))
    print("PostHog public configuration and build provenance bundled.")


if __name__ == "__main__":
    try:
        main()
    except (ConfigurationError, OSError) as error:
        sys.exit(f"PostHog configuration failed: {error}")
