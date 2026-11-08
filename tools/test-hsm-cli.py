#!/usr/bin/env python3
"""tools/hsm against the real root runtime: new, validate, pack."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HSM = ROOT / "tools/hsm"


def hsm(*args, cwd, code=0):
    result = subprocess.run([sys.executable, str(HSM), *args], cwd=cwd, capture_output=True, text=True, timeout=300)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr


def main():
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        out = hsm("new", "demo-mod", cwd=work)
        assert "created demo-mod" in out, out
        hsm("new", "demo-mod", cwd=work, code=1)
        hsm("new", "Bad_Id", cwd=work, code=1)
        out = hsm("validate", "demo-mod", cwd=work)
        assert "ok demo-mod 0.1.0" in out and "owns_props=persist.sys.demo_mod.level" in out, out

        module = work / "demo-mod"
        apply = module / "apply.sh"
        original = apply.read_text()
        apply.write_text(original + "reboot now\n")
        out = hsm("validate", "demo-mod", cwd=work, code=2)
        assert "HSM-E110 apply.sh:4: unknown verb: reboot" in out, out

        wifi = "/system/etc/permissions/android.hardware.wifi.xml"
        (module / "files/wifi.xml").write_text("<permissions/>\n")
        apply.write_text(original + f"put_file {wifi} files/wifi.xml\n")
        out = hsm("validate", "demo-mod", cwd=work, code=3)
        assert "same file or line as wifi" in out, out

        apply.write_text(original)
        # The template targets every car; a module narrowed to one firmware refuses the others.
        hsm("validate", "demo-mod", "--product", "OTHER.CAR", cwd=work)
        props = module / "module.properties"
        props.write_text(props.read_text().replace("cars=*\n", "cars=NEEV.KOR.*.260902\n"))
        out = hsm("validate", "demo-mod", "--product", "OTHER.CAR", cwd=work, code=4)
        assert "state=incompatible" in out, out

        first = hsm("pack", "demo-mod", "--out", "dist", cwd=work).splitlines()
        second = hsm("pack", "demo-mod", "--out", "dist", "--no-validate", cwd=work).splitlines()
        assert first[-2].endswith("dist/demo-mod-0.1.0.hsm") and first[-1] == second[-1], (first, second)
        assert len(first[-1]) == 64
    print("hsm cli tests passed")


if __name__ == "__main__":
    sys.exit(main())
