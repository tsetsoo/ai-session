"""Secret redaction shared by ai-todo-memory and ai-todo-sessions (Python 3 stdlib only).

Installed next to the scripts as ~/.ai-remote/bin/ai_todo_redact.py; both scripts import it
from their own directory. Every match is replaced with [REDACTED:<type>]:

  private_key      PEM "-----BEGIN ... PRIVATE KEY-----" blocks (to the END line, or the end of the text)
  local_secret     literal values of TODO_API_TOKEN and of *_TOKEN/*_KEY/*_SECRET/*_PASSWORD
                   variables in the environment (values of 8+ characters), passed as extra_secrets
  url_credentials  [user]:password in scheme://user:pass@host, up to the last @ before the host
  basic_auth, auth_token, bearer
                   the value after "Authorization: Basic|Token|Bearer" (and any "Bearer <token>")
  cli_credentials  user:pass after curl -u / --user
  cli_secret       --password/--token/--api-key/--secret values, mysql -p<value>, sshpass -p <value>
  jwt              eyJ....<...>.<...>
  anthropic_key, openai_key, github_token, gitlab_token, slack_token, aws_key, google_key,
  stripe_key       prefixed provider tokens
  secret           the value in password=..., token: "...", api_key=... (the key is kept; quoted
                   values are taken whole; values that are code - null, None, true, await ...,
                   name(...), self./this./os.environ/process.env/getenv - are left alone)
  random           strings of 32+ characters of [A-Za-z0-9+/_=-] with letters and digits that
                   are not made of words (see _looks_random). Hex ids (git SHAs, sha256 digests,
                   32-hex ids) and UUIDs are kept unless a secret keyword (key, token, secret,
                   password, auth, credential, bearer) comes right before them.

Usage as a filter: python3 ai_todo_redact.py <in >out (secrets from the environment).
"""
import re
import sys

_TOKEN_START = r"(?<![A-Za-z0-9])"
_QUOTED_OR_WORD = r"(\"[^\"\n]*\"|'[^'\n]*'|[^\s\"']+)"

_PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S)
# Greedy up to the last "@" that is followed by a host, so "/" and "@" inside a password are covered.
_URL_CREDENTIALS = re.compile(r"(?<=://)[^\s/@:]*:\S+(?=@[A-Za-z0-9\[])")
_AUTH_HEADER = re.compile(r"(\bAuthorization\s*[:=]\s*[\"']?\s*)(Basic|Token|Bearer)(\s+)([^\s\"',;]+)", re.I)
_AUTH_KINDS = {"basic": "basic_auth", "token": "auth_token", "bearer": "bearer"}
_BEARER = re.compile(r"(\bbearer\s+)([A-Za-z0-9._~+/=-]{8,})", re.I)
_CLI_USER = re.compile(r"((?:^|\s)(?:-u|--user)(?:\s+|=))(\"[^\"\n]*:[^\"\n]*\"|'[^'\n]*:[^'\n]*'|[^\s\"':]*:[^\s\"']+)", re.M)
_CLI_FLAG = re.compile(r"((?:^|\s)--(?:password|passwd|pass|token|api-key|apikey|api_key|secret|client-secret"
                       r"|access-token|auth-token)(?:\s+|=))" + _QUOTED_OR_WORD, re.M | re.I)
_MYSQL = re.compile(r"(\b(?:mysql|mysqldump|mysqladmin|mariadb)\b[^\n;&|]*?\s-p)(\"[^\"\n]*\"|'[^'\n]*'|[^\s\"'-]\S*)")
_SSHPASS = re.compile(r"(\bsshpass\b(?:\s+-[A-Za-oq-z]\S*)*\s+-p\s*)" + _QUOTED_OR_WORD)
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
    r"(?<![A-Za-z0-9])([A-Za-z0-9_.-]*?(?:password|passwd|secret|token|api[_-]?key|access[_-]?key"
    r"|private[_-]?key|client[_-]?secret))([\"']?\s*[:=]\s*)" + _QUOTED_OR_WORD,
    re.I,
)
# Unquoted values that are code, not a secret: keywords/literals, calls, attribute and env lookups.
_CODE_VALUE = re.compile(
    r"^(?:(?:await|new|null|none|nil|true|false|undefined)(?![A-Za-z0-9_])"
    r"|[A-Za-z_][\w.]*\(|(?:self|this)\.|os\.environ|process\.env|(?:os\.)?getenv|=)",
    re.I,
)
_RANDOM = re.compile(r"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])")
_HEX_ID = re.compile(r"(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{40}|[0-9a-fA-F]{64}|[0-9a-fA-F]{128})")
_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_SECRET_CONTEXT = re.compile(r"key|token|secret|passw|auth|credential|bearer", re.I)
# A segment that reads as a word: lower/Title/UPPER/camelCase with at most a short number, a
# number, or a version like v2.
_WORD = re.compile(r"^(?:[a-z]+|[A-Z][a-z]+|[A-Z]+|(?:[A-Z][a-z]+)+|[a-z]+(?:[A-Z][a-z]+)+|[A-Z]+(?:[A-Z][a-z]+)+)\d{0,3}$"
                   r"|^\d+$|^v\d+[a-z]?\d*$")
_LETTER = re.compile(r"[A-Za-z]")
_DIGIT = re.compile(r"[0-9]")
_ENV_SECRET_NAME = re.compile(r"_(TOKEN|KEY|SECRET|PASSWORD)$")
_MIN_LOCAL_SECRET = 8


def _mark(kind):
    return "[REDACTED:" + kind + "]"


def _is_id(text):
    return bool(_HEX_ID.fullmatch(text) or _UUID.fullmatch(text))


def _looks_random(text, secret_context):
    """Letters and digits, and most of it is not made of word-like segments. Hex ids and
    UUIDs only count in a secret context."""
    if not (_LETTER.search(text) and _DIGIT.search(text)):
        return False
    if secret_context:
        return True
    if _is_id(text):
        return False
    segments = [s for s in re.split(r"[-_/.+=]+", text) if s]
    odd = sum(len(s) for s in segments if len(s) > 3 and not _WORD.match(s) and not _is_id(s))
    return odd * 2 >= sum(len(s) for s in segments)


def _key_value(match):
    value = match.group(3)
    if value.startswith("[REDACTED:") or (value[0] not in "\"'" and _CODE_VALUE.match(value)):
        return match.group(0)
    return match.group(1) + match.group(2) + _mark("secret")


def _random(text):
    def replace(match):
        value = match.group(0)
        # The keyword may sit right before it, or inside it as in "key=<hex>".
        before = text[max(0, match.start() - 24):match.start()] + value[:value.rfind("=") + 1]
        if _looks_random(value, bool(_SECRET_CONTEXT.search(before))):
            return _mark("random")
        return match.group(0)
    return _RANDOM.sub(replace, text)


def _keep_prefix(kind):
    return lambda m: m.group(1) + (_mark(kind) if not m.group(2).startswith("[REDACTED:") else m.group(2))


def redact(text, extra_secrets=()):
    """Return text with every secret replaced by [REDACTED:<type>]. Unicode text is untouched."""
    if not text:
        return text
    text = _PEM.sub(_mark("private_key"), text)
    for secret in sorted({s for s in extra_secrets if s and len(s) >= _MIN_LOCAL_SECRET}, key=len, reverse=True):
        text = text.replace(secret, _mark("local_secret"))
    text = _URL_CREDENTIALS.sub(_mark("url_credentials"), text)
    text = _AUTH_HEADER.sub(lambda m: m.group(1) + m.group(2) + m.group(3) + _mark(_AUTH_KINDS[m.group(2).lower()]), text)
    text = _BEARER.sub(_keep_prefix("bearer"), text)
    text = _CLI_USER.sub(_keep_prefix("cli_credentials"), text)
    text = _CLI_FLAG.sub(_keep_prefix("cli_secret"), text)
    text = _MYSQL.sub(_keep_prefix("cli_secret"), text)
    text = _SSHPASS.sub(_keep_prefix("cli_secret"), text)
    text = _JWT.sub(_mark("jwt"), text)
    for kind, pattern in _PREFIXED:
        text = pattern.sub(_mark(kind), text)
    text = _KEY_VALUE.sub(_key_value, text)
    return _random(text)


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
