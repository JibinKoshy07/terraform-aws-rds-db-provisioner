import os
import re
import json
import base64
import secrets
import logging

import boto3
import psycopg2
from psycopg2 import sql

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("secretsmanager")

SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "postgres")

IDENT = re.compile(r"^[a-z][a-z0-9_]{2,62}$")
RESERVED = {"postgres", "rdsadmin", "public", "template0", "template1", "rds_superuser"}

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS public.database_n_credentials (
    "DB_USERNAME" VARCHAR(63) PRIMARY KEY,
    "DB_NAME" VARCHAR(63) UNIQUE NOT NULL,
    "DB_PASSWORD" TEXT NOT NULL,
    "RDS_ENDPOINT" VARCHAR(255) NOT NULL
)
"""


def resp(code, payload):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def valid(name):
    return (
        isinstance(name, str)
        and IDENT.fullmatch(name) is not None
        and not name.startswith("pg_")
        and name not in RESERVED
    )


def parse_params(event):
    body = event.get("body")
    if body is None:  # console test / direct invoke
        return event
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    return json.loads(body) if isinstance(body, str) else body


def lambda_handler(event, context):
    try:
        params = parse_params(event)
        if not isinstance(params, dict):
            raise ValueError
    except (ValueError, UnicodeDecodeError):
        return resp(400, {"status": "FAILED", "message": "Body must be a JSON object."})

    db_name = params.get("database_name", "")
    db_user = params.get("username", "")

    if not valid(db_name) or not valid(db_user):
        return resp(400, {
            "status": "FAILED",
            "message": "database_name and username must be 3-63 chars: lowercase "
                       "letters, digits, underscore, starting with a letter. "
                       "Reserved and pg_* names are not allowed.",
        })

    admin = json.loads(sm.get_secret_value(SecretId=SECRET_ARN)["SecretString"])
    admin_user = admin["username"]

    conn = None
    role_created = db_created = grant_active = False
    locks = sorted({db_name, db_user})

    try:
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=admin_user, password=admin["password"],
            sslmode="require", connect_timeout=10,
        )
        conn.autocommit = True  # CREATE DATABASE can't run in a transaction

        with conn.cursor() as cur:
            cur.execute(CREATE_TABLE)

            for name in locks:
                cur.execute("SELECT pg_advisory_lock(hashtext(%s))", (name,))

            try:
                cur.execute(
                    'SELECT "DB_USERNAME", "DB_NAME", "RDS_ENDPOINT" '
                    'FROM public.database_n_credentials '
                    'WHERE "DB_NAME" = %s OR "DB_USERNAME" = %s',
                    (db_name, db_user),
                )
                row = cur.fetchone()
                if row:
                    if row[0] == db_user and row[1] == db_name:
                        return resp(200, {
                            "status": "EXISTS", "database": db_name,
                            "username": db_user, "endpoint": row[2], "port": DB_PORT,
                        })
                    return resp(409, {"status": "CONFLICT",
                                      "message": "Database or username already registered."})

                cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db_name,))
                if cur.fetchone():
                    return resp(409, {"status": "CONFLICT",
                                      "message": "Database exists but is not registered."})

                cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (db_user,))
                if cur.fetchone():
                    return resp(409, {"status": "CONFLICT",
                                      "message": "Role already exists."})

                db_password = secrets.token_urlsafe(32)

                cur.execute(
                    sql.SQL("CREATE ROLE {} WITH LOGIN PASSWORD %s")
                    .format(sql.Identifier(db_user)),
                    (db_password,),
                )
                role_created = True

                # RDS master isn't a true superuser: it must be able to SET ROLE
                # to the owner before it can create a database owned by it.
                cur.execute(
                    sql.SQL("GRANT {} TO {} WITH SET TRUE")
                    .format(sql.Identifier(db_user), sql.Identifier(admin_user))
                )
                grant_active = True

                cur.execute(
                    sql.SQL("CREATE DATABASE {} OWNER {}")
                    .format(sql.Identifier(db_name), sql.Identifier(db_user))
                )
                db_created = True

                cur.execute(
                    sql.SQL("REVOKE {} FROM {}")
                    .format(sql.Identifier(db_user), sql.Identifier(admin_user))
                )
                grant_active = False

                cur.execute(
                    'INSERT INTO public.database_n_credentials '
                    '("DB_USERNAME", "DB_NAME", "DB_PASSWORD", "RDS_ENDPOINT") '
                    'VALUES (%s, %s, %s, %s)',
                    (db_user, db_name, db_password, DB_HOST),
                )

                logger.info("Created database %s and role %s", db_name, db_user)
                return resp(201, {
                    "status": "CREATED", "database": db_name, "username": db_user,
                    "password": db_password,  # returned only on creation
                    "endpoint": DB_HOST, "port": DB_PORT,
                })

            except Exception:
                logger.exception("Provisioning failed for %s / %s", db_name, db_user)
                # Best-effort rollback of whatever this invocation created.
                for flag, stmt in (
                    (grant_active, sql.SQL("REVOKE {} FROM {}").format(
                        sql.Identifier(db_user), sql.Identifier(admin_user))),
                    (db_created, sql.SQL("DROP DATABASE IF EXISTS {}").format(
                        sql.Identifier(db_name))),
                    (role_created, sql.SQL("DROP ROLE IF EXISTS {}").format(
                        sql.Identifier(db_user))),
                ):
                    if flag:
                        try:
                            cur.execute(stmt)
                        except Exception:
                            logger.exception("Cleanup step failed")
                raise

            finally:
                for name in reversed(locks):
                    try:
                        cur.execute("SELECT pg_advisory_unlock(hashtext(%s))", (name,))
                    except Exception:
                        logger.exception("Could not release advisory lock")

    except Exception as exc:
        logger.exception("Provisioning error")
        return resp(500, {"status": "FAILED", "errorType": type(exc).__name__,
                          "message": "Internal error. Check CloudWatch logs."})

    finally:
        if conn is not None:
            conn.close()