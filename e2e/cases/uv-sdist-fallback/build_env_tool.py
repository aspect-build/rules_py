from pathlib import Path


payload = Path(__file__).with_name("build_env_tool.txt").read_text(encoding="utf-8")
if payload != "runfile available\n":
    raise RuntimeError(f"unexpected runfile contents: {payload!r}")
