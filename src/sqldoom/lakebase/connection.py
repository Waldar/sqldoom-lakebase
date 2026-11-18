"""Lakebase endpoints, OAuth credentials and raw pgwire logins for the app.

The app talks to Lakebase as its own Databricks identity (the app service
principal when deployed, the developer when run by hand). Lakebase accepts a
short-lived OAuth token as the Postgres password; a token only has to be valid
when a connection logs in, so long-lived sessions survive its expiry and only
new logins need a fresh one.

Env:
  LAKEBASE_ENDPOINT          the production branch's endpoint, which holds the lobby
                             (default projects/sqldoom/branches/production/endpoints/primary)
  LAKEBASE_DB (databricks_postgres), LAKEBASE_SCHEMA (doom)
  LAKEBASE_USER              Postgres role to log in as (default: the caller's Databricks user name)
  LAKEBASE_TOKEN_REFRESH_S   reuse a token for this long (default 2400 s; tokens last 1 h)
"""
import asyncio
import os
import ssl
import struct
import threading
import time

import psycopg2.extensions

DB = os.getenv("LAKEBASE_DB", "databricks_postgres")
SCHEMA = os.getenv("LAKEBASE_SCHEMA", "doom")
TOKEN_REFRESH_S = float(os.getenv("LAKEBASE_TOKEN_REFRESH_S", "2400"))
# Every session: the game schema, and commits that do not wait for the WAL to
# be durable on the safekeepers (~4 ms per tic).
SESSION_OPTIONS = f"-c search_path={SCHEMA} -c synchronous_commit=off"


def endpoints():
    """Pane name -> Lakebase endpoint resource name: the production primary."""
    return {"primary": os.getenv("LAKEBASE_ENDPOINT",
                                 "projects/sqldoom/branches/production/endpoints/primary")}


class Credentials:
    """Endpoint hosts and OAuth tokens, cached per endpoint. Thread-safe."""

    def __init__(self):
        self._lock = threading.Lock()
        self._w = None
        self._user = None
        self._hosts = {}
        self._tokens = {}      # endpoint -> (token, fetched_at)

    def _client(self):
        if self._w is None:
            from databricks.sdk import WorkspaceClient
            self._w = WorkspaceClient()
        return self._w

    def user(self):
        with self._lock:
            if self._user is None:
                # For a service principal user_name is its application id,
                # which is also its Postgres role name in Lakebase.
                self._user = os.getenv("LAKEBASE_USER") or self._client().current_user.me().user_name
            return self._user

    def host(self, endpoint):
        with self._lock:
            if endpoint not in self._hosts:
                self._hosts[endpoint] = self._client().postgres.get_endpoint(name=endpoint).status.hosts.host
            return self._hosts[endpoint]

    def token(self, endpoint):
        with self._lock:
            cached = self._tokens.get(endpoint)
            if cached and time.time() - cached[1] < TOKEN_REFRESH_S:
                return cached[0]
            token = self._client().postgres.generate_database_credential(endpoint=endpoint).token
            self._tokens[endpoint] = (token, time.time())
            return token

    def dsn(self, endpoint, application_name="sqldoom-app", role=None):
        """libpq DSN with a fresh-enough token (psycopg2). role: SET ROLE for
        the session (e.g. doom_owner, so objects it creates are owned by the
        shared owner role and not by the logged-in identity)."""
        options = SESSION_OPTIONS + (f" -c role={role}" if role else "")
        return psycopg2.extensions.make_dsn(
            host=self.host(endpoint), port=5432, dbname=DB, user=self.user(),
            password=self.token(endpoint), sslmode="require",
            application_name=application_name, options=options,
            connect_timeout=10, keepalives=1, keepalives_idle=30, tcp_user_timeout=15000)


CREDS = Credentials()


# ------------------------------------------------------------ raw pgwire login
class PgLoginError(Exception):
    pass


AUTH_OK = b"R" + struct.pack("!ii", 8, 0)
_SSL_REQUEST = struct.pack("!ii", 8, 80877103)
_PROTOCOL_3 = 196608
_TLS = ssl.create_default_context()


def error_response(text, code="08006", severity="FATAL"):
    """A Postgres ErrorResponse message, for refusing a browser in its own protocol."""
    body = b"".join(k + v.encode() + b"\0" for k, v in
                    ((b"S", severity), (b"V", severity), (b"C", code), (b"M", text))) + b"\0"
    return b"E" + struct.pack("!i", len(body) + 4) + body


def error_text(body):
    fields = {}
    for part in body.split(b"\0"):
        if part:
            fields[chr(part[0])] = part[1:].decode("utf-8", "replace")
    return fields.get("M", "database error")


async def read_message(reader):
    """(type byte, whole message bytes, body) of one backend message."""
    head = await reader.readexactly(5)
    n = int.from_bytes(head[1:5], "big")
    body = await reader.readexactly(n - 4)
    return head[:1], head + body, body


async def open_session(endpoint, application_name, player=None):
    """Log in to a Lakebase endpoint over TLS with the app's OAuth token.

    Returns (reader, writer, tail): an authenticated asyncio stream pair and the
    bytes the server sent after AuthenticationOk up to and including the first
    ReadyForQuery (ParameterStatus, BackendKeyData, ReadyForQuery). A relay
    replays AUTH_OK + tail to a browser in place of the browser's own login.
    """
    host, user, token = await asyncio.to_thread(
        lambda: (CREDS.host(endpoint), CREDS.user(), CREDS.token(endpoint)))
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host, 5432), 10)
    try:
        writer.write(_SSL_REQUEST)
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(1), 10) != b"S":
            raise PgLoginError(f"{host} refused TLS")
        await writer.start_tls(_TLS, server_hostname=host)
        params = b"".join(k.encode() + b"\0" + v.encode() + b"\0" for k, v in (
            ("user", user), ("database", DB), ("client_encoding", "UTF8"),
            ("application_name", application_name),
            # doom.player names the caller for the player API (doom_caller());
            # the relay passes an identity limited to [A-Za-z0-9@._+#-].
            ("options", SESSION_OPTIONS + (f" -c doom.player={player}" if player else "")))) + b"\0"
        writer.write(struct.pack("!ii", len(params) + 8, _PROTOCOL_3) + params)
        await writer.drain()
        tail = bytearray()
        while True:
            kind, msg, body = await asyncio.wait_for(read_message(reader), 15)
            if kind == b"R":
                code = int.from_bytes(body[:4], "big")
                if code == 3:                      # AuthenticationCleartextPassword
                    pw = token.encode() + b"\0"
                    writer.write(b"p" + struct.pack("!i", len(pw) + 4) + pw)
                    await writer.drain()
                elif code != 0:
                    raise PgLoginError(f"unsupported authentication request {code}")
            elif kind == b"E":
                raise PgLoginError(error_text(body))
            else:
                tail += msg
                if kind == b"Z":
                    return reader, writer, bytes(tail)
    except BaseException:
        writer.close()
        raise
