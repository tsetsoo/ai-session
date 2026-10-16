"""Secret redaction shared by ai-todo-memory and ai-todo-sessions (Python 3 stdlib only).

Installed next to the scripts as ~/.ai-remote/bin/ai_todo_redact.py; both scripts import it
from their own directory. Every match is replaced with [REDACTED:<type>]:

  private_key      PEM "-----BEGIN ... PRIVATE KEY-----" blocks (to the END line, or the end of the text)
  local_secret     literal values of TODO_API_TOKEN and of *_TOKEN/*_KEY/*_SECRET/*_PASSWORD
                   variables in the environment (values of 8+ characters), passed as extra_secrets
  url_credentials  user:pass in scheme://user:pass@host (the scheme and host are kept)
  bearer           the token after "Bearer " (the word is kept)
  jwt              eyJ....<...>.<...>
  anthropic_key, openai_key, github_token, gitlab_token, slack_token, aws_key, google_key,
  stripe_key       prefixed provider tokens
  secret           the value in password=..., token: ..., api_key=... (the key is kept)
  random           high-entropy strings of 32+ characters of [A-Za-z0-9+/_=-] with letters and
                   digits; 40-hex git SHAs and UUIDs are kept

Usage as a filter: python3 ai_todo_redact.py <in >out (secrets from the environment).
"""
import math
import re
import sys

_TOKEN_START = r"(?<![A-Za-z0-9])"

_PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S)
_URL_CREDENTIALS = re.compile(r"(?<=://)[^\s/@:]+:[^\s/@]+(?=@)")
_BEARER = re.compile(r"(\bbearer\s+)([A-Za-z0-9._~+/=-]{8,})", re.I)
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}")
_PREFIXED = [
    ("anthropic_key", re.compile(_TOKEN_START + r"sk-ant-[A-Za-z0-9_-]{8,}")),
    ("openai_key", re.compile(_TOKEN_START + r"sk-[A-Za-z0-9_-]{17,}")),
    ("github_token", re.compile(_TOKEN_START + r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})")),
    ("gitlab_token", re.compile(_TOKEN_START + r"glpat-[A-Za-z0-9_-]{20,}")),
    ("slack_token", re.compile(_TOKEN_START + r"xox[abposr]-[A-Za-z0-9-]{10,}")),
    ("aws_key", re.compile(_TOKEN_START + r"AKIA[0-9A-Z]{16}(?![0-9A-Z])")),
    ("google_key", re.compile(_TOKEN_START + r"AIza[0-9A-Za-z_-]{35}")),
    ("stripe_key", re.compile(_TOKEN_START + r"[rs]k_(?:live|test)_[A-Za-z0-9]{10,}")),
]
_KEY_VALUE = re.compile(
    r"(?<![A-Za-z0-9])([A-Za-z0-9_.-]*?(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key"
    r"|private[_-]?key|client[_-]?secret))([\"']?\s*[:=]\s*)(\S+)",
    re.I,
)
_RANDOM = re.compile(r"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])")
_GIT_SHA = re.compile(r"[0-9a-fA-F]{40}")
_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_ENV_SECRET_NAME = re.compile(r"_(TOKEN|KEY|SECRET|PASSWORD)$")
_MIN_LOCAL_SECRET = 8


def _mark(kind):
    return "[REDACTED:" + kind + "]"


def _entropy(text):
    counts = {}
    for ch in text:
        counts[ch] = counts.get(ch, 0) + 1
    n = float(len(text))
    return -sum(c / n * math.log(c / n, 2) for c in counts.values())


def _looks_random(text):
    if _GIT_SHA.fullmatch(text) or _UUID.fullmatch(text):
        return False
    if not (re.search(r"[A-Za-z]", text) and re.search(r"[0-9]", text)):
        return False
    # Letter/digit switches: random strings have many, names like "release-v2" have few.
    switches = sum(1 for a, b in zip(text, text[1:]) if a.isdigit() != b.isdigit() and (a.isalnum() and b.isalnum()))
    return switches >= 4 and _entropy(text) >= 3.0


def _key_value(match):
    value = match.group(3)
    if value.startswith("[REDACTED:"):
        return match.group(0)
    return match.group(1) + match.group(2) + _mark("secret")


def redact(text, extra_secrets=()):
    """Return text with every secret replaced by [REDACTED:<type>]. Unicode text is untouched."""
    if not text:
        return text
    text = _PEM.sub(_mark("private_key"), text)
    for secret in sorted({s for s in extra_secrets if s and len(s) >= _MIN_LOCAL_SECRET}, key=len, reverse=True):
        text = text.replace(secret, _mark("local_secret"))
    text = _URL_CREDENTIALS.sub(_mark("url_credentials"), text)
    text = _BEARER.sub(lambda m: m.group(1) + _mark("bearer"), text)
    text = _JWT.sub(_mark("jwt"), text)
    for kind, pattern in _PREFIXED:
        text = pattern.sub(_mark(kind), text)
    text = _KEY_VALUE.sub(_key_value, text)
    text = _RANDOM.sub(lambda m: _mark("random") if _looks_random(m.group(0)) else m.group(0), text)
    return text


def secret_values_from_env(env):
    """Values of TODO_API_TOKEN and *_TOKEN/*_KEY/*_SECRET/*_PASSWORD variables (8+ chars)."""
    values = set()
    for name, value in env.items():
        if not isinstance(value, str):
            continue
        value = value.strip()
        if len(value) < _MIN_LOCAL_SECRET:
            continue
        if name == "TODO_API_TOKEN" or _ENV_SECRET_NAME.search(name):
            values.add(value)
    return sorted(values, key=len, reverse=True)


if __name__ == "__main__":
    import os

    sys.stdout.write(redact(sys.stdin.read(), secret_values_from_env(os.environ)))
