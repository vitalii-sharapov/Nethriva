#!/usr/bin/env python3
"""Bounded, local-only SSH identity regression. Never uses real credentials.

Runs an unprivileged sshd on 127.0.0.1 with generated throwaway host keys,
no authorized user keys, no PAM/password login, and private known_hosts.
The correct-key case intentionally ends at authentication refusal.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def check_host_identity():
    for executable in ["/usr/bin/ssh", "/usr/bin/ssh-keygen", "/usr/sbin/sshd"]:
        if not os.access(executable, os.X_OK):
            raise RuntimeError("Required system OpenSSH fixture executable unavailable")
    with tempfile.TemporaryDirectory(prefix="Nethriva-SSH-Security-") as folder:
        root = Path(folder)
        root.chmod(0o700)
        for name in ["host", "other-host"]:
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)],
                           check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = root / "sshd_config"
        config.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {root}/host
PidFile {root}/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile none
LoginGraceTime 5
MaxStartups 3
LogLevel ERROR
""")
        known = root / "known_hosts"
        base = ["/usr/bin/ssh", "-F", "none", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={known}", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "UpdateHostKeys=no", "-o", "IdentityAgent=none", "-o", "IdentityFile=none",
                "-o", "CertificateFile=none", "-o", "PreferredAuthentications=none",
                "-o", "PubkeyAuthentication=no", "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no", "-o", "HostbasedAuthentication=no",
                "-o", "GSSAPIAuthentication=no", "-o", "ConnectTimeout=2",
                "-p", str(port), "--", "synthetic-user@127.0.0.1"]
        with (root / "sshd.log").open("wb") as log:
            server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)],
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            try:
                ready = False
                for _ in range(40):
                    if server.poll() is not None:
                        raise RuntimeError("Unprivileged synthetic sshd could not start; no real service/configuration was changed")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            ready = True
                        break
                    except OSError:
                        time.sleep(0.05)
                if not ready:
                    raise RuntimeError("Synthetic loopback SSH listener did not become ready")
                results = []
                for label, key in [("unknown key rejected", None), ("changed key rejected", "other-host"), ("correct key accepted before intentional auth refusal", "host")]:
                    content = ""
                    if key:
                        public = (root / (key + ".pub")).read_text().split()
                        content = f"[127.0.0.1]:{port} {public[0]} {public[1]}\n"
                    known.write_text(content)
                    known.chmod(0o600)
                    value = subprocess.run(base, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=6)
                    error = value.stderr
                    if key is None:
                        passed = value.returncode == 255 and b"Host key verification failed" in error
                    elif key == "other-host":
                        passed = value.returncode == 255 and b"REMOTE HOST IDENTIFICATION HAS CHANGED" in error
                    else:
                        passed = value.returncode == 255 and b"Permission denied" in error and b"Host key verification failed" not in error
                    passed = passed and known.read_text() == content
                    results.append({"case": label, "passed": passed})
                if not all(item["passed"] for item in results):
                    raise RuntimeError("Synthetic SSH identity regression failed; private fixture logs were not published")
                return results
            finally:
                if server.poll() is None:
                    os.killpg(server.pid, signal.SIGTERM)
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait(timeout=3)


if __name__ == "__main__":
    print(json.dumps({"scope": "synthetic loopback only; no passwords/private user keys/authentication", "cases": check_host_identity()}, indent=2))
