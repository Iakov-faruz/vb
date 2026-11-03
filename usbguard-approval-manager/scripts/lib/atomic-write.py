#!/usr/bin/env python3
"""Write one JSON document atomically with file and directory fsync."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import stat
import sys
from pathlib import Path

FILE_MODE = 0o600
TEMP_ATTEMPTS = 10
MAX_JSON_SIZE = 1 * 1024 * 1024  # 1 MiB


class AtomicWriteError(Exception):
    """An atomic write failed; replaced indicates whether rename completed."""

    def __init__(self, message: str, *, replaced: bool = False) -> None:
        super().__init__(message)
        self.replaced = replaced


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"invalid JSON constant: {value}")


def write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("failed to complete file write")
        view = view[written:]


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_json_document(document: str) -> None:
    """Validate JSON syntax, reject non-standard constants, and reject duplicate keys."""
    try:
        encoded = document.encode("utf-8")
    except UnicodeEncodeError as error:
        raise AtomicWriteError("input contains invalid Unicode text") from error
    if len(encoded) > MAX_JSON_SIZE:
        raise AtomicWriteError(f"input exceeds maximum JSON size of {MAX_JSON_SIZE} bytes")
    try:
        json.loads(
            document,
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (json.JSONDecodeError, ValueError) as error:
        raise AtomicWriteError(f"input is not valid JSON: {error}") from error


def _create_temp_file(directory_fd: int, target_name: str) -> tuple[int, str]:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0)

    for _ in range(TEMP_ATTEMPTS):
        temp_name = f".{target_name}.{secrets.token_hex(8)}.tmp"
        try:
            file_fd = os.open(
                temp_name,
                flags,
                FILE_MODE,
                dir_fd=directory_fd,
            )
        except FileExistsError:
            continue
        try:
            os.fchmod(file_fd, FILE_MODE)
        except OSError:
            os.close(file_fd)
            os.unlink(temp_name, dir_fd=directory_fd)
            raise
        return file_fd, temp_name

    raise AtomicWriteError("could not reserve a unique temporary file")


def atomic_write_json(target_path: str | os.PathLike[str], document: str) -> None:
    """Validate and atomically replace target_path with the provided JSON."""
    validate_json_document(document)
    try:
        payload = document.encode("utf-8")
    except UnicodeEncodeError as error:
        raise AtomicWriteError("input contains invalid Unicode text") from error

    target = Path(target_path)
    if target.name in ("", ".", ".."):
        raise AtomicWriteError("target must name a file")

    try:
        parent = target.parent.resolve(strict=True)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_fd = os.open(parent, directory_flags)
    except OSError as error:
        raise AtomicWriteError("target directory is unavailable") from error

    temp_name: str | None = None
    replaced = False
    try:
        try:
            existing = os.stat(
                target.name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            existing = None

        if existing is not None:
            if stat.S_ISLNK(existing.st_mode):
                raise AtomicWriteError("refusing to replace a symbolic link")
            if not stat.S_ISREG(existing.st_mode):
                raise AtomicWriteError("target is not a regular file")

        file_fd, temp_name = _create_temp_file(directory_fd, target.name)
        try:
            write_all(file_fd, payload)
            os.fsync(file_fd)
        finally:
            os.close(file_fd)

        # Rename by directory descriptor, avoiding a second path lookup.
        os.replace(
            temp_name,
            target.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        replaced = True
        temp_name = None

        # A failure here means the new file is visible but durability is unknown.
        os.fsync(directory_fd)
    except AtomicWriteError:
        raise
    except OSError as error:
        state = (
            "target was replaced but durability is uncertain"
            if replaced
            else "target was not replaced"
        )
        raise AtomicWriteError(
            f"{state}: {error.strerror or error}",
            replaced=replaced,
        ) from error
    finally:
        try:
            if temp_name is not None:
                os.unlink(temp_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        finally:
            os.close(directory_fd)


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, help="target file path")
    parser.add_argument("--data", help="JSON document to write")
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate the existing file without modifying it",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = _parse_args(sys.argv[1:] if arguments is None else arguments)
    if options.validate_only:
        if options.data is not None:
            print(
                "atomic-write: ERROR: --data cannot be used with --validate-only",
                file=sys.stderr,
            )
            return 2
        try:
            file_fd = os.open(
                options.file,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
        except OSError as error:
            print(f"atomic-write: ERROR: {error}", file=sys.stderr)
            return 1
        try:
            file_stat = os.fstat(file_fd)
            if not stat.S_ISREG(file_stat.st_mode):
                print("atomic-write: ERROR: target is not a regular file", file=sys.stderr)
                return 1
            raw = os.read(file_fd, MAX_JSON_SIZE + 1)
            if len(raw) > MAX_JSON_SIZE:
                print("atomic-write: ERROR: input exceeds maximum JSON size", file=sys.stderr)
                return 1
            try:
                document = raw.decode("utf-8")
            except UnicodeDecodeError as error:
                print(f"atomic-write: ERROR: {error}", file=sys.stderr)
                return 1
            validate_json_document(document)
        except (OSError, AtomicWriteError) as error:
            print(f"atomic-write: ERROR: {error}", file=sys.stderr)
            return 1
        finally:
            os.close(file_fd)
        return 0
    if options.data is None:
        print("atomic-write: ERROR: --data is required unless using --validate-only", file=sys.stderr)
        return 2
    try:
        atomic_write_json(options.file, options.data)
    except AtomicWriteError as error:
        print(f"atomic-write: ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
