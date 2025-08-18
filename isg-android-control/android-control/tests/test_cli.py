from types import SimpleNamespace
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from isg_android_control import cli


def _dummy_settings():
    return SimpleNamespace(api=SimpleNamespace(host="0.0.0.0", port=8000))


def test_cmd_stop_invalid_pid_file(tmp_path, monkeypatch, capsys):
    pid_file = tmp_path / "pid"
    pid_file.write_text("not-a-number")
    monkeypatch.setattr(cli, "PID_FILE", pid_file)
    monkeypatch.setattr(cli.Settings, "load", staticmethod(_dummy_settings))

    rc = cli.cmd_stop()
    out = capsys.readouterr().out.lower()

    assert rc == 1
    assert "invalid pid file" in out
    assert not pid_file.exists()


def test_cmd_status_invalid_pid_file(tmp_path, monkeypatch, capsys):
    pid_file = tmp_path / "pid"
    pid_file.write_text("bad")
    monkeypatch.setattr(cli, "PID_FILE", pid_file)

    rc = cli.cmd_status()
    out = capsys.readouterr().out.lower()

    assert rc == 3
    assert "invalid pid file" in out
    assert not pid_file.exists()
