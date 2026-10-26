"""Exercise the real runner/IPC against a harmless fake tunnel, without root."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "build/tests/runner"
ENV = {**os.environ, "UW_VPN_TEST_OPENCONNECT": str(ROOT / "build/tests/fake-openconnect")}
checks = 0


def run_case(name, *, drop=False, early_stop=False, natural_exit=False, malformed=False):
    global checks
    with tempfile.TemporaryDirectory(prefix="uw-vpn-test.", dir="/tmp") as directory:
        path = str(Path(directory) / "control")
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            os.chmod(path, 0o600)
            listener.listen(1)
            listener.settimeout(5)
            process = subprocess.Popen([str(RUNNER), path, str(os.getuid())], env=ENV,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                channel, _ = listener.accept()
                channel.settimeout(8)
                stream = channel.makefile("rwb", buffering=0)

                def receive():
                    line = stream.readline()
                    return json.loads(line) if line else None

                def send(message):
                    stream.write(json.dumps(message).encode() + b"\n")

                assert receive()["kind"] == "ready"
                if early_stop:
                    send({"kind": "stop"})
                    assert receive() == {"kind": "exited", "code": 0}
                else:
                    cookie = "test-cookie-exit" if natural_exit else "test-cookie-secret"
                    send({"kind": "start", "session": {
                        "cookie": cookie, "server": "http://bad.example" if malformed else "https://vpn.example",
                        "fingerprint": "pin-sha256:abcDEF123+/=", "resolve": "vpn.example:192.0.2.1",
                        "reconnectTimeout": 3600}})
                    messages = []
                    child_pid = None
                    if not malformed:
                        while True:
                            message = receive()
                            assert message is not None, "runner closed before connected"
                            messages.append(message)
                            if message["kind"] == "log" and message["text"].startswith("mock pid:"):
                                child_pid = int(message["text"].split(":")[1])
                            if message["kind"] == "connected":
                                break
                        if drop:
                            stream.close()
                            channel.close()
                        else:
                            if not natural_exit:
                                send({"kind": "stop"})
                            while True:
                                message = receive()
                                if message is None:
                                    break
                                messages.append(message)
                                if message["kind"] == "exited":
                                    break
                            expected = 7 if natural_exit else 0
                            assert messages[-1] == {"kind": "exited", "code": expected}, messages
                            if not natural_exit:
                                assert any("mock route and DNS cleanup" in m.get("text", "") for m in messages)
                            assert cookie not in json.dumps(messages), "cookie leaked to diagnostics"
                    process.wait(timeout=8)
                    if child_pid:
                        try:
                            os.kill(child_pid, 0)
                        except ProcessLookupError:
                            pass
                        else:
                            raise AssertionError("mock tunnel survived runner cleanup")
                    assert process.returncode == (1 if malformed else 0), process.stderr.read()
                stream.close()
                channel.close()
                process.wait(timeout=5)
                checks += 1
                print("PASS:", name)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


run_case("connect, cookie isolation, stop and cleanup")
run_case("GUI crash / EOF tears down tunnel", drop=True)
run_case("cancel before authentication", early_stop=True)
run_case("natural tunnel failure reports exit status", natural_exit=True)
run_case("malformed session refused before tunnel launch", malformed=True)

release = ROOT / "build/UW VPN.app/Contents/MacOS/uw-vpn-runner"
refused = subprocess.run([str(release), "/tmp/unused", str(os.getuid())], capture_output=True, text=True)
assert refused.returncode == 1 and "requires administrator" in refused.stderr
checks += 1
print(f"Passed {checks} integration scenarios; no VPN login or privileged commands used.")
