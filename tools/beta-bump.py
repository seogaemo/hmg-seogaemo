#!/usr/bin/env python3
"""Keep the long-lived `beta` branch one release ahead after a release is published.

  beta-bump.py final --tag vX.Y.Z       final published: merge it into beta, then
                                        VERSION=X.Y.(Z+1) and PRERELEASE=beta.1
  beta-bump.py beta  --tag vX.Y.Z-beta.N  beta published: PRERELEASE=beta.(N+1)

Runs inside a clone with an `origin` remote and a committer identity; it pushes
only `beta`. Re-running after success changes nothing. A conflicting merge pushes
nothing and fails. Two kinds of conflict are resolved: VERSION/PRERELEASE in favour
of beta (they are rewritten right after), and committed build outputs (GENERATED)
by rebuilding them from the merged sources with their make target; the rebuild must
change no other tracked file.
"""
import argparse
import pathlib
import re
import subprocess
import sys

# importing version.py must not leave tools/__pycache__ behind: the clean-tree check below would fail
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import version as versionlib  # noqa: E402  (the checked-out tools/version.py may change when beta is checked out)

BRANCH = "beta"
FIRST = "beta.1"
PUSH_ATTEMPTS = 3
VERSION_FILES = ("VERSION", "PRERELEASE")
# Committed build outputs and the make target that rebuilds each from its sources.
GENERATED = {"modules/wireless-carplay-and-aa/files/wireless-mod.jar": "module-build"}
TAG = re.compile(r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]?))?")


class Skip(Exception):
    """Nothing to do; reported and exits 0."""


class Failure(Exception):
    """Needs a human; reported and exits 1."""


def parse(value):
    return tuple(int(part) for part in value.split("."))


def after_final(final, version, pre):
    """(VERSION, PRERELEASE) for beta once final X.Y.Z shipped; beta already ahead stays."""
    if parse(version) > parse(final):
        return version, pre or FIRST
    major, minor, patch = parse(final)
    return f"{major}.{minor}.{patch + 1}", FIRST


def after_beta(tag_version, tag_number, version, pre):
    """PRERELEASE for the next beta, or None when beta's tip is not at the published beta."""
    if version != tag_version or pre != f"beta.{tag_number}":
        return None
    if tag_number >= 99:
        raise Failure(f"beta.{tag_number} is the last beta number for {version}; bump VERSION on beta by hand")
    return f"beta.{tag_number + 1}"


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and result.returncode:
        raise Failure(f"git {' '.join(args)} failed:\n{result.stdout}{result.stderr}")
    return result


def ok(*args):
    return git(*args, check=False).returncode == 0


def read_state():
    """VERSION and PRERELEASE of the checked-out tree (pre is None without the file)."""
    root = pathlib.Path(git("rev-parse", "--show-toplevel").stdout.strip())
    version, _ = versionlib.read_version(root / "VERSION")
    pre_file = root / "PRERELEASE"
    return version, (pre_file.read_text(encoding="ascii").strip() if pre_file.exists() else None)


def write_state(version, pre):
    root = pathlib.Path(git("rev-parse", "--show-toplevel").stdout.strip())
    (root / "VERSION").write_text(version + "\n", encoding="ascii")
    (root / "PRERELEASE").write_text(pre + "\n", encoding="ascii")
    versionlib.read_label(root / "VERSION")  # refuse to commit anything the build would reject


def commit_state(version, pre):
    """Commit VERSION/PRERELEASE when they changed."""
    write_state(version, pre)
    git("add", *VERSION_FILES)
    if ok("diff", "--cached", "--quiet"):
        return False
    git("commit", "-m", f"beta: {version}-{pre}")
    return True


def fetch(remote):
    git("fetch", "--tags", "--force", remote)


def tag_commit(tag):
    result = git("rev-parse", "--verify", "-q", f"refs/tags/{tag}^{{commit}}", check=False)
    if result.returncode:
        raise Failure(f"tag {tag} not found in the clone")
    return result.stdout.strip()


def push(remote):
    """True once the push went through, False when beta moved meanwhile."""
    return ok("push", remote, f"HEAD:refs/heads/{BRANCH}")


def merge_final(tag, commit):
    """Merge the released commit into the checked-out beta; abort and fail on a real conflict."""
    if ok("merge-base", "--is-ancestor", commit, "HEAD"):
        return False
    merged = git("merge", "--no-ff", "--no-commit", commit, check=False)
    if merged.returncode:
        conflicts = git("diff", "--name-only", "--diff-filter=U").stdout.split()
        if not conflicts or set(conflicts) - set(VERSION_FILES) - set(GENERATED):
            abort_merge(tag, f"conflicts in: {' '.join(conflicts) or '(unknown)'}")
        versions = [name for name in conflicts if name in VERSION_FILES]
        if versions:
            git("checkout", "--ours", "--", *versions)
            git("add", *versions)
        outputs = [name for name in conflicts if name in GENERATED]
        if outputs:
            rebuild(tag, outputs)
    git("commit", "-m", f"Merge {tag} into {BRANCH}")
    return True


def abort_merge(tag, reason):
    git("merge", "--abort", check=False)
    git("reset", "--hard", "-q", "HEAD", check=False)  # a failed rebuild may have touched tracked files
    raise Failure(f"merging {tag} into {BRANCH} {reason}.\n"
                  f"Nothing was pushed. Merge {tag} into {BRANCH} by hand, resolve it, then set "
                  "VERSION to the next patch and PRERELEASE to beta.1 in a separate commit.")


def rebuild(tag, outputs):
    """Rebuild conflicting build outputs from the merged sources and stage them."""
    git("checkout", "--theirs", "--", *outputs)
    for target in sorted({GENERATED[name] for name in outputs}):
        built = subprocess.run(["make", target], capture_output=True, text=True)
        if built.returncode:
            tail = (built.stdout + built.stderr)[-2000:]
            abort_merge(tag, f"conflicts in {' '.join(outputs)} and `make {target}` failed:\n{tail}")
    git("add", "--", *outputs)
    # Only the outputs may change; anything else means the build is not reproducible here.
    stray = git("diff", "--name-only").stdout.split()
    if stray:
        abort_merge(tag, f"rebuild of {' '.join(outputs)} also changed: {' '.join(stray)}")


def sync_final(tag, version, remote):
    commit = tag_commit(tag)
    if not ok("merge-base", "--is-ancestor", commit, f"{remote}/main"):
        raise Failure(f"{tag} is not contained in {remote}/main")
    for _ in range(PUSH_ATTEMPTS):
        fetch(remote)
        if ok("rev-parse", "--verify", "-q", f"refs/remotes/{remote}/{BRANCH}"):
            git("checkout", "-B", BRANCH, f"{remote}/{BRANCH}")
            changed = merge_final(tag, commit)
        else:
            git("checkout", "-B", BRANCH, commit)
            changed = True
        current, pre = read_state()
        changed |= commit_state(*after_final(version, current, pre))
        if not changed:
            raise Skip(f"{BRANCH} already follows {tag}")
        if push(remote):
            return f"{BRANCH} now at {'-'.join(filter(None, read_state()))}"
    raise Failure(f"{BRANCH} kept moving; gave up after {PUSH_ATTEMPTS} attempts, re-run the job")


def sync_beta(tag, version, number, remote):
    commit = tag_commit(tag)
    for _ in range(PUSH_ATTEMPTS):
        fetch(remote)
        if not ok("rev-parse", "--verify", "-q", f"refs/remotes/{remote}/{BRANCH}"):
            raise Skip(f"no {remote}/{BRANCH}")
        if not ok("merge-base", "--is-ancestor", commit, f"{remote}/{BRANCH}"):
            raise Failure(f"{tag} is not contained in {remote}/{BRANCH}")
        git("checkout", "-B", BRANCH, f"{remote}/{BRANCH}")
        current, pre = read_state()
        following = after_beta(version, number, current, pre)
        if following is None:
            raise Skip(f"{BRANCH} is at {current}-{pre or 'final'}, not {tag}; leaving it")
        commit_state(current, following)
        if push(remote):
            return f"{BRANCH} now at {current}-{following}"
    raise Failure(f"{BRANCH} kept moving; gave up after {PUSH_ATTEMPTS} attempts, re-run the job")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kind", choices=("final", "beta"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--remote", default="origin")
    args = parser.parse_args()
    match = TAG.fullmatch(args.tag)
    if not match or (match.group(2) is None) != (args.kind == "final"):
        parser.error(f"{args.tag} is not a {args.kind} release tag")
    version, number = match.group(1), match.group(2)
    try:
        if git("status", "--porcelain", "--untracked-files=no").stdout.strip():
            raise Failure("working tree is not clean")
        if args.kind == "final":
            note = sync_final(args.tag, version, args.remote)
        else:
            note = sync_beta(args.tag, version, int(number), args.remote)
    except Skip as skip:
        print(f"::notice::skipped: {skip}")
        return 0
    except Failure as failure:
        print(f"::error::{failure}")
        return 1
    print(note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
