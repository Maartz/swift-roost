#!/usr/bin/env python3
"""Run the jobs of .github/workflows/ci.yml on this machine, against the committed checkout.

- swift test, with POSTGRES_URL on a throwaway database so the job queue tests run
- swift test in a Linux container (Docker), unless this machine runs Linux
- swift test --traits Valkey, against VALKEY_URL or a temporary valkey-server or redis-server
- the example app against this checkout: build, migrate, swift test, and its browser tests
- roost-cli's generated-app acceptance check, with --release

Needs a local PostgreSQL server and its client tools. DB_HOST, DB_PORT, DB_USER,
and DB_PASSWORD configure it, as for the example's helpers. ROOST_* variables are
ignored, because CI tests the published companion packages. The Linux job keeps
its build in the Docker volume roost-local-ci-build between runs.
"""

import argparse
import contextlib
import getpass
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid


ROOT = Path(__file__).resolve().parent.parent
# ci.yml installs Swift 6.3.3.
LINUX_IMAGE = "swift:6.3-noble"
# The longest a command may run, which includes a cold build.
TIMEOUT = 30 * 60


def run(arguments, log, **kwargs):
    """Runs a command, logging its output. A hung test run fails after TIMEOUT instead of blocking the script."""
    arguments = [str(argument) for argument in arguments]
    with open(log, "a") as out:
        print("+ " + shlex.join(arguments), file=out, flush=True)
        # A session of its own, so a timeout also stops the test runner that swift test starts.
        process = subprocess.Popen(arguments, stdout=out, stderr=subprocess.STDOUT, start_new_session=True, **kwargs)
        try:
            code = process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError(f"Stopped after {TIMEOUT // 60} minutes: {shlex.join(arguments)}")
    if code:
        raise subprocess.CalledProcessError(code, arguments)


@contextlib.contextmanager
def database(env, log):
    name = "roost_local_ci_" + uuid.uuid4().hex[:12]
    run(["createdb", name], log, env=env)
    try:
        yield name
    finally:
        run(["dropdb", "--force", "--if-exists", name], log, env=env)


def without_database(env):
    """CI's framework jobs set no DB_* variables, which some tests read."""
    return {key: value for key, value in env.items() if not key.startswith(("DB_", "PG"))}


def framework(env, log):
    with database(env, log) as name:
        user, password = (urllib.parse.quote(env[key], safe="") for key in ("DB_USER", "DB_PASSWORD"))
        url = f"postgres://{user}:{password}@{env['DB_HOST']}:{env['DB_PORT']}/{name}"
        run(["swift", "test"], log, cwd=ROOT, env=dict(without_database(env), POSTGRES_URL=url))


def linux(env, log):
    # Killing docker run leaves the container running, so it times out by itself.
    script = ("set -e; mkdir /work; tar -x -C /work; apt-get update -qq; apt-get install -y -qq zlib1g-dev;"
              f" cd /work; timeout -s KILL {TIMEOUT} swift test --scratch-path /build")
    archive = subprocess.Popen(["git", "archive", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE)
    run(["docker", "run", "--rm", "-i", "-v", "roost-local-ci-build:/build", LINUX_IMAGE, "bash", "-c", script],
        log, stdin=archive.stdout)
    archive.stdout.close()
    if archive.wait() != 0:
        raise RuntimeError("git archive failed")


def valkey(env, log):
    env = without_database(env)
    if env.get("VALKEY_URL"):
        return run(["swift", "test", "--traits", "Valkey"], log, cwd=ROOT, env=env)
    server = shutil.which("valkey-server") or shutil.which("redis-server")
    if not server:
        raise RuntimeError("Set VALKEY_URL, or install valkey-server or redis-server")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    process = subprocess.Popen([server, "--port", str(port), "--save", "", "--appendonly", "no"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError(f"{server} didn't start on port {port}")
                time.sleep(0.1)
        run(["swift", "test", "--traits", "Valkey"], log, cwd=ROOT, env=dict(env, VALKEY_URL=f"valkey://127.0.0.1:{port}"))
    finally:
        process.terminate()
        process.wait()


def example(env, log):
    app = ROOT / "examples/Roost"
    browser_tests = app / "BrowserTests"
    with database(env, log) as name:
        env = dict(env, ROOST_FRAMEWORK_PATH=str(ROOT), DB_NAME=name)
        run(["swift", "build", "--product", "RoostExample"], log, cwd=app, env=env)
        bin_path = subprocess.run(["swift", "build", "--show-bin-path"], cwd=app, env=env, capture_output=True,
                                  text=True, check=True).stdout.strip().splitlines()[-1]
        run([Path(bin_path) / "RoostExample", "migrate", "up"], log, cwd=app, env=env)
        run(["swift", "test"], log, cwd=app, env=env)
        if not (browser_tests / "node_modules").exists():
            run(["npm", "ci"], log, cwd=browser_tests)
        run(["npx", "playwright", "install", "chromium"], log, cwd=browser_tests)
        run(["npm", "test"], log, cwd=browser_tests, env=env)


def generated_app(env, log, cli):
    script = cli / "scripts/check_generated_app.py"
    if not script.exists():
        raise RuntimeError(f"Missing {script}: pass --cli with a roost-cli checkout")
    run([sys.executable, script, "--framework", ROOT, "--release"], log, cwd=cli, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", type=Path, default=ROOT.parent / "roost-cli",
                        help="roost-cli checkout for the acceptance check (default: ../roost-cli)")
    args = parser.parse_args()
    changes = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout
    if changes:
        sys.exit("Commit or stash your changes first: CI tests commits, and so does the Linux job.")
    for tool in ("swift", "createdb", "dropdb"):
        if not shutil.which(tool):
            sys.exit(f"Install {tool} and put it on PATH.")

    env = {key: value for key, value in os.environ.items() if not key.startswith("ROOST_")}
    env.setdefault("DB_HOST", "localhost")
    env.setdefault("DB_PORT", "5432")
    env.setdefault("DB_USER", getpass.getuser())
    env.setdefault("DB_PASSWORD", "")
    env.update(PGHOST=env["DB_HOST"], PGPORT=env["DB_PORT"], PGUSER=env["DB_USER"], PGPASSWORD=env["DB_PASSWORD"])
    logs = Path(tempfile.mkdtemp(prefix="roost-local-ci-"))
    print(f"Logs: {logs}", flush=True)
    failed = []

    def attempt(name, job):
        log = logs / (name.replace(" ", "-") + ".log")
        start = time.monotonic()
        try:
            job(env, log)
            print(f"✔ {name} ({time.monotonic() - start:.0f}s)", flush=True)
        except (subprocess.CalledProcessError, RuntimeError, OSError) as error:
            with open(log, "a") as out:
                print(error, file=out)
            print(f"✘ {name} ({time.monotonic() - start:.0f}s): {log}", flush=True)
            failed.append(name)

    # The container builds apart from this machine, so it runs alongside the other jobs.
    container = None
    if sys.platform != "linux":
        container = threading.Thread(target=attempt, args=("linux", linux))
        container.start()
    attempt("framework", framework)
    attempt("valkey", valkey)
    attempt("example", example)
    attempt("generated app", lambda env, log: generated_app(env, log, args.cli))
    if container:
        container.join()
    sys.exit(f"Failed: {', '.join(failed)}" if failed else 0)


if __name__ == "__main__":
    main()
