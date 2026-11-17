"""The game's database: installed and upgraded from the SQL files in sql/."""
from .install import SQL_ROOT, code_version, install, status

__all__ = ["SQL_ROOT", "code_version", "install", "status"]
