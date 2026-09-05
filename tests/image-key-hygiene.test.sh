#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Execute the actual install RUN and SSH startup block against nonsecret fixtures.
# No Docker, root privileges, real keys, or host /etc/ssh changes are needed.
# Image acceptance must additionally inspect every layer, not just the merged FS.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
dockerfile = (root / "worker/Dockerfile").read_text()
entrypoint = (root / "worker/entrypoint.sh").read_text()
checks = 0


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def passed(message):
    global checks
    checks += 1
    print(f"PASS: {message}")


def install_run(source):
    logical = re.sub(r"\\\n", " ", source)
    runs = re.findall(r"^RUN (.*)$", logical, re.M)
    matches = [run for run in runs if "apt-get install" in run and "openssh-server" in run]
    require(len(matches) == 1, "expected one OpenSSH installation RUN")
    return matches[0]


with tempfile.TemporaryDirectory(prefix="image-key-hygiene-") as tmp:
    base = Path(tmp)
    bindir = base / "bin"
    bindir.mkdir()
    # apt-get models the package's key-creation side effect, not the package itself.
    apt = bindir / "apt-get"
    apt.write_text('''#!/bin/bash
set -eu
if [[ "$1" == install ]]; then
  if [[ "${INSTALL_STATUS:-0}" != 0 ]]; then exit "$INSTALL_STATUS"; fi
  for kind in rsa ecdsa ed25519 future; do
    printf 'NONSECRET PRIVATE FIXTURE\\n' > "$KEY_DIR/ssh_host_${kind}_key"
    printf 'NONSECRET PUBLIC FIXTURE\\n' > "$KEY_DIR/ssh_host_${kind}_key.pub"
  done
fi
''')
    apt.chmod(0o755)
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": tmp}

    def packaging(source, install_status=0):
        with tempfile.TemporaryDirectory(dir=tmp) as case:
            case = Path(case)
            ssh = case / "ssh"
            lists = case / "lists"
            ssh.mkdir()
            lists.mkdir()
            for name in ("sshd_config", "ssh_config", "moduli"):
                (ssh / name).write_text("PRESERVE\n")
            (ssh / "sshd_config.d").mkdir()
            (lists / "fixture").touch()
            command = install_run(source).replace("/etc/ssh/", f"{ssh}/")
            command = command.replace("/var/lib/apt/lists/", f"{lists}/")
            result = subprocess.run(["bash", "-euc", command], env={
                **env, "KEY_DIR": str(ssh), "INSTALL_STATUS": str(install_status)
            }, capture_output=True, text=True)
            require(result.returncode == install_status, "installation status was not preserved")
            require(not list(ssh.glob("ssh_host_*_key*")), "keys survive the installation layer")
            for name in ("sshd_config", "ssh_config", "moduli"):
                require((ssh / name).read_text() == "PRESERVE\n", "unrelated SSH file changed")
            require((ssh / "sshd_config.d").is_dir(), "SSH config directory removed")
            if install_status == 0:
                require(not list(lists.iterdir()), "apt lists cleanup regressed")

    packaging(dockerfile)
    passed("install layer removes private/public keys (including future types), preserves config")
    packaging(dockerfile, 23)
    passed("package installation failure propagates")

    cleanup = " && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "
    original_run = install_run(dockerfile)
    require(original_run.count(cleanup) == 1, "expected same-layer host-key cleanup")
    without_cleanup = original_run.replace(cleanup, " ")
    regressions = {
        "missing cleanup": "RUN " + without_cleanup,
        "later-layer whiteout": "RUN " + without_cleanup + "\nRUN" + cleanup[3:],
        "private-only cleanup": "RUN " + original_run.replace(" /etc/ssh/ssh_host_*_key.pub", ""),
        "cleanup before installation": "RUN " + cleanup[4:].strip() + " && " + without_cleanup,
    }
    for label, broken in regressions.items():
        try:
            packaging(broken)
        except RuntimeError as error:
            require(str(error) == "keys survive the installation layer", f"unexpected failure: {label}")
        else:
            raise RuntimeError(f"regression was accepted: {label}")
        passed(f"rejects {label}")

    match = re.search(r"^# SSH server\n(.*?)^echo .*Starting SSH server", entrypoint, re.M | re.S)
    require(match is not None, "cannot locate runtime SSH key-generation block")
    block = match.group(1)
    ssh = base / "runtime-ssh"
    ssh.mkdir()
    calls = base / "keygen-calls"
    # Model ssh-keygen -A's create-missing-only contract; image tests use real OpenSSH.
    keygen = bindir / "ssh-keygen"
    keygen.write_text('''#!/bin/bash
set -eu
[[ "$#" == 1 && "$1" == -A ]] || exit 90
printf 'called\\n' >> "$CALLS"
if [[ "${KEYGEN_STATUS:-0}" != 0 ]]; then exit "$KEYGEN_STATUS"; fi
for kind in rsa ecdsa ed25519; do
  if [[ ! -f "$KEY_DIR/ssh_host_${kind}_key" ]]; then
    printf 'NONSECRET RUNTIME FIXTURE\\n' > "$KEY_DIR/ssh_host_${kind}_key"
    chmod 600 "$KEY_DIR/ssh_host_${kind}_key"
  fi
done
''')
    keygen.chmod(0o755)

    def runtime(status=0):
        result = subprocess.run(["bash", "-euc", block.replace("/etc/ssh/", f"{ssh}/")],
                                env={**env, "KEY_DIR": str(ssh), "CALLS": str(calls),
                                     "KEYGEN_STATUS": str(status)}, capture_output=True, text=True)
        require(result.returncode == status, "runtime key generation status was not preserved")

    def metadata():
        return {p.name: (p.stat().st_ino, p.stat().st_mtime_ns, p.stat().st_ctime_ns, p.stat().st_mode)
                for p in ssh.iterdir()}

    runtime()
    require(len(metadata()) == 3 and calls.read_text().splitlines() == ["called"], "fresh startup failed")
    passed("fresh startup requests ssh-keygen -A")
    before = metadata()
    runtime()
    require(metadata() == before and calls.read_text().splitlines() == ["called"], "restart replaced keys")
    passed("restart preserves existing keys without generation")
    (ssh / "ssh_host_ed25519_key").unlink()  # Only our nonsecret fixture.
    before = metadata()
    runtime()
    require(all(metadata()[name] == value for name, value in before.items()), "existing key replaced")
    require(len(metadata()) == 3, "missing runtime key was not generated")
    passed("missing ed25519 triggers generation while preserving other keys")
    (ssh / "ssh_host_ed25519_key").unlink()
    runtime(17)
    require(not (ssh / "ssh_host_ed25519_key").exists(), "failed generation unexpectedly succeeded")
    passed("key-generation failure stops startup")

print(f"Image key hygiene: PASS ({checks} checks)")
PY
