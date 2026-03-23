import sqlite3
import uuid
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any
from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def _get_conn(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, check_same_thread=False, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db(db_path: str, default_users_str: str) -> None:
    conn = _get_conn(db_path)
    try:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                hashed_password TEXT NOT NULL,
                cluster_user TEXT NOT NULL,
                is_admin INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                slurm_job_id INTEGER,
                user_id TEXT NOT NULL,
                cluster_user TEXT NOT NULL,
                name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'SUBMITTED',
                input_prefix TEXT NOT NULL,
                cpus INTEGER NOT NULL DEFAULT 1,
                memory_mb INTEGER NOT NULL DEFAULT 800,
                time_limit TEXT NOT NULL DEFAULT '01:00:00',
                command TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                error_message TEXT,
                FOREIGN KEY (user_id) REFERENCES users(id)
            );

            CREATE INDEX IF NOT EXISTS idx_jobs_user_id ON jobs(user_id);
            CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
        """)
        conn.commit()

        # Seed default users
        now = datetime.now(timezone.utc).isoformat()
        for entry in default_users_str.split(","):
            parts = entry.strip().split(":")
            if len(parts) != 4:
                continue
            username, password, cluster_user, is_admin_str = parts
            is_admin = int(is_admin_str)

            existing = conn.execute(
                "SELECT id FROM users WHERE username = ?", (username,)
            ).fetchone()
            if existing is None:
                user_id = str(uuid.uuid4())
                hashed = pwd_context.hash(password)
                conn.execute(
                    """INSERT INTO users (id, username, hashed_password, cluster_user, is_admin, created_at)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (user_id, username, hashed, cluster_user, is_admin, now),
                )
        conn.commit()
    finally:
        conn.close()


def get_user_by_username(db_path: str, username: str) -> Optional[Dict[str, Any]]:
    conn = _get_conn(db_path)
    try:
        row = conn.execute(
            "SELECT * FROM users WHERE username = ?", (username,)
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def get_user_by_id(db_path: str, user_id: str) -> Optional[Dict[str, Any]]:
    conn = _get_conn(db_path)
    try:
        row = conn.execute(
            "SELECT * FROM users WHERE id = ?", (user_id,)
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def create_job(db_path: str, job_dict: Dict[str, Any]) -> Dict[str, Any]:
    conn = _get_conn(db_path)
    try:
        now = datetime.now(timezone.utc).isoformat()
        job_id = job_dict.get("id", str(uuid.uuid4()))
        conn.execute(
            """INSERT INTO jobs
               (id, slurm_job_id, user_id, cluster_user, name, status, input_prefix,
                cpus, memory_mb, time_limit, command, created_at, updated_at, error_message)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                job_id,
                job_dict.get("slurm_job_id"),
                job_dict["user_id"],
                job_dict["cluster_user"],
                job_dict["name"],
                job_dict.get("status", "SUBMITTED"),
                job_dict["input_prefix"],
                job_dict.get("cpus", 1),
                job_dict.get("memory_mb", 800),
                job_dict.get("time_limit", "01:00:00"),
                job_dict["command"],
                job_dict.get("created_at", now),
                job_dict.get("updated_at", now),
                job_dict.get("error_message"),
            ),
        )
        conn.commit()
        return get_job(db_path, job_id)
    finally:
        conn.close()


def get_job(
    db_path: str, job_id: str, user_id: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    conn = _get_conn(db_path)
    try:
        if user_id is not None:
            row = conn.execute(
                "SELECT * FROM jobs WHERE id = ? AND user_id = ?", (job_id, user_id)
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM jobs WHERE id = ?", (job_id,)
            ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def list_jobs(
    db_path: str, user_id: str, is_admin: bool = False
) -> List[Dict[str, Any]]:
    conn = _get_conn(db_path)
    try:
        if is_admin:
            rows = conn.execute(
                "SELECT * FROM jobs ORDER BY created_at DESC"
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM jobs WHERE user_id = ? ORDER BY created_at DESC",
                (user_id,),
            ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def update_job(db_path: str, job_id: str, updates: Dict[str, Any]) -> None:
    if not updates:
        return
    conn = _get_conn(db_path)
    try:
        updates["updated_at"] = datetime.now(timezone.utc).isoformat()
        set_clause = ", ".join(f"{k} = ?" for k in updates)
        values = list(updates.values()) + [job_id]
        conn.execute(f"UPDATE jobs SET {set_clause} WHERE id = ?", values)
        conn.commit()
    finally:
        conn.close()


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)
