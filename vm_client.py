"""SSH helper for the verified development VM."""

from __future__ import annotations

import base64
import getpass
import hashlib
import hmac
from typing import Final

import paramiko

VM_HOST: Final = "10.161.199.60"
VM_USERNAME: Final = "yf"
VM_HOST_KEY_SHA256: Final = "SHA256:JfLmAo/XVg61fKPqCPekFaYiz/QdGC/laOQDJezgIDk"
DEFAULT_TIMEOUT_SECONDS: Final = 15


class PinnedHostKeyPolicy(paramiko.MissingHostKeyPolicy):
    """Accept only the VM host key whose fingerprint was verified out of band."""

    def missing_host_key(
        self,
        client: paramiko.SSHClient,
        hostname: str,
        key: paramiko.PKey,
    ) -> None:
        digest = base64.b64encode(hashlib.sha256(key.asbytes()).digest())
        fingerprint = f"SHA256:{digest.decode('ascii').rstrip('=')}"
        if not hmac.compare_digest(fingerprint, VM_HOST_KEY_SHA256):
            raise paramiko.SSHException(
                f"untrusted SSH host key for {hostname}: {fingerprint}"
            )
        client.get_host_keys().add(hostname, key.get_name(), key)


class VMCommandError(RuntimeError):
    """A remote command returned a non-zero exit status."""

    def __init__(self, exit_status: int, stderr: str, stdout: str) -> None:
        self.exit_status = exit_status
        self.stderr = stderr
        self.stdout = stdout
        detail = stderr.strip() or stdout.strip() or "no command output"
        super().__init__(f"VM command failed with exit status {exit_status}: {detail}")


def _connect(client: paramiko.SSHClient, timeout: int, password: str | None) -> None:
    connection_options = {
        "hostname": VM_HOST,
        "username": VM_USERNAME,
        "timeout": timeout,
        "banner_timeout": timeout,
        "auth_timeout": timeout,
    }
    if password is None:
        try:
            client.connect(
                **connection_options,
                allow_agent=True,
                look_for_keys=True,
            )
        except paramiko.AuthenticationException:
            password = getpass.getpass(f"SSH password for {VM_USERNAME}@{VM_HOST}: ")
    if password is not None:
        if not password:
            raise paramiko.AuthenticationException("SSH password was not provided")
        client.connect(
            **connection_options,
            password=password,
            allow_agent=False,
            look_for_keys=False,
        )


def execute_on_vm(
    command: str,
    *,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
    password: str | None = None,
    stdin_data: str | None = None,
) -> str:
    """Run a command on the pinned VM and return stdout (plus any successful stderr)."""
    if not command.strip():
        raise ValueError("command must not be empty")
    if type(timeout) is not int or timeout < 1:
        raise ValueError("timeout must be a positive integer")

    client = paramiko.SSHClient()
    client.load_system_host_keys()
    client.set_missing_host_key_policy(PinnedHostKeyPolicy())
    try:
        _connect(client, timeout, password)
        stdin, stdout, stderr = client.exec_command(command, timeout=timeout)

        # כתיבה ל-stdin לפני קריאת הפלט למניעת Deadlock
        if stdin_data is not None:
            stdin.write(stdin_data)
            stdin.flush()
            stdin.channel.shutdown_write()

        output = stdout.read().decode("utf-8", errors="replace")
        error_output = stderr.read().decode("utf-8", errors="replace")
        exit_status = stdout.channel.recv_exit_status()

        if exit_status != 0:
            raise VMCommandError(exit_status, error_output, output)
        if error_output:
            return f"{output.rstrip()}\n[stderr]\n{error_output}".strip()
        return output
    finally:
        client.close()
