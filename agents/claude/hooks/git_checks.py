"""Checks on calls that run git or gh: a push that rewrites main or skips the repository's hooks, a merge or label
that bypasses `pr-land`, a HEAD move in a repository's main checkout, a `git worktree add` outside the worktrees
folder, and a GitHub post that still holds a placeholder.

Sessions share a repository's main checkout, so a `git checkout <rev>`, `git switch`, or `git reset --hard` there
changes the files under every other session working in it. A linked worktree is a session's own, and so are the
default branch, a path restore (`git checkout -- <path>` or `git checkout <path>`), a soft or mixed reset, and a
clone under /tmp or $TMPDIR. A checkout is the main one when its git dir is the common git dir.

The shared rules let an agent rebase a published branch, and `--force-with-lease` refuses to push when the remote
branch moved since the last fetch, so a lease push to a branch the command names passes. The label check does not
read a label that comes from a file inside a value (`-F 'labels[]=@file'`), from `$(cat file)`, or from a pipe into
`xargs`; it does read an `--input` file.

Every check fails open: a command that does not parse, a directory git cannot read, or a file that cannot be read lets
the call through. The placeholder check also searches the raw command text, so a command that does not parse still gets
that search.
"""
import os
import re
import shutil

from checkouts import git as git_output
from checkouts import is_shared_checkout

PLACEHOLDER = re.compile(
    r"\d+x{3,}\b|\bX{3,}\b|\bTBD\b|<\s*(?:fill|placeholder|todo|insert)[^>]*>",
    re.IGNORECASE,
)
MKTEMP_TEMPLATE = re.compile(r"X{3,}")
GH_VALUE_OPTIONS = {"-R", "--repo", "--hostname"}
GH_LONG = "|".join(re.escape(option) for option in sorted(GH_VALUE_OPTIONS) if option.startswith("--"))
GH_SHORT = "".join(re.escape(option[1:]) for option in sorted(GH_VALUE_OPTIONS) if not option.startswith("--"))
GH_OPTION = rf"(?:\s+(?:(?:{GH_LONG})(?:\s+|=)|-[{GH_SHORT}]\s*)\S+)*"
POSTING = re.compile(rf"\bgh{GH_OPTION}\s+(?:(?:issue|pr){GH_OPTION}\s+(?:comment|create|edit|review|close)|api\b)")
# Bytes of a post body file that the check reads (guess); GitHub takes at most 65536 characters in a body.
PLACEHOLDER_CAP = 1 << 20
FORCE_FLAGS = {"-f", "--force"}
LEASE_FLAGS = {"--force-with-lease", "--force-if-includes"}
DEFAULT_BRANCHES = {"main", "master"}
# `git push` options that may take the next word as their value.
PUSH_VALUE_OPTIONS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
LABEL = "automerge"
# The short options of each command that take a value, as a bundle such as `-dl automerge` reads them: `-f` is a
# value for `gh api` and a flag for `gh pr create`.
CREATE_VALUES = "aBbFHlmprRTt"
EDIT_VALUES = "BbFmRt"
COMMENT_VALUES = "bF"
POST_VALUES = {"create": CREATE_VALUES, "edit": EDIT_VALUES, "comment": COMMENT_VALUES, "review": COMMENT_VALUES}
API_VALUES = "FfHpqXt"
# The git subcommands whose `--no-verify` skips a hook, and the `git commit` short options that take a value, so `-mn`
# is a message and not `-n`.
VERIFY_COMMANDS = {"commit", "push", "merge", "rebase", "am"}
COMMIT_VALUES = "mFCct"
# `git commit` short options whose value may only follow attached, as in `-uno` or `-Skey`.
COMMIT_ATTACHED = "uS"
# `git branch` options that take the next word as a value, even when it starts with a dash, as in `--sort -authordate`.
BRANCH_VALUE_OPTIONS = {"--sort", "--format", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
# `gh api` paths that write a PR's labels: `issues/N/labels`, `issues/N` (PATCH takes a labels list), and `labels`.
LABEL_PATH = re.compile(r"(?:^|/)(?:labels(?:/|$)|issues/[^/]+(?:/labels(?:/[^/]*)?)?$)")
# Bytes of a `gh api --input` file that the hook reads (guess); a request body that sets labels is far smaller.
INPUT_CAP = 1 << 20


# Options that create a branch or detach HEAD, so the call moves HEAD whatever else it names.
MOVING = {"-b", "-B", "-c", "-C", "--create", "--force-create", "--orphan", "--detach", "-d"}
HARD_RESETS = {"--hard", "--keep", "--merge"}
CHECKOUT_REASON = (
    "This is the repository's main checkout, which other sessions share, and this call moves its HEAD. Work on "
    "another revision in your own worktree, as the worktrees skill says: `wt switch --create <type>/<slug> --no-cd` "
    "for a branch, `git worktree add --detach ~/Desktop/workspace/worktrees/<repo>/review-<sha7> <rev>` for a "
    "revision. Omer can still run it himself with the `!` prefix."
)
WORKTREE_ROOT = os.path.expanduser("~/Desktop/workspace/worktrees")
WORKTREE_REASON = (
    "This `git worktree add` puts the worktree outside ~/Desktop/workspace/worktrees/<repo>/, the layout the worktrees "
    "skill and pr-land use. For a branch run `wt switch --create <type>/<slug> --base origin/main --no-cd`; for a "
    "revision run `git worktree add --detach ~/Desktop/workspace/worktrees/<repo>/review-<sha7> <rev>`. Write the path "
    "as an absolute one when an earlier `cd` in the same call changes the directory."
)
ADD_VALUE_OPTIONS = {"-b", "-B", "--reason"}
COMMIT_THEN_PUSH_REASON = (
    "This pushes even when the `git commit` before it fails, and then publishes whatever HEAD already held, "
    "such as Omer's unpushed commits. Join the commit and the push with `&&`, or push in a later call after "
    "the commit exits 0 and `git log origin/<branch>..HEAD` lists only your commits."
)


def _gh_words(args):
    """(group, verb, rest) of the words after `gh`. gh's own options that take a value, such as `-R o/r`, may sit
    anywhere before the verb. For `gh api` the word after the group is the endpoint, so the verb is "" and rest holds
    every word after the group."""
    at, k = [], 0
    while k < len(args):
        if args[k].startswith("-"):
            k += 2 if args[k] in GH_VALUE_OPTIONS else 1
            continue
        at.append(k)
        k += 1
        if len(at) == 2 or args[at[0]] == "api":
            break
    if not at:
        return "", "", []
    if len(at) == 1:
        return args[at[0]], "", args[at[0] + 1:]
    return args[at[0]], args[at[1]], [a for j, a in enumerate(args) if j not in at]


def _force_push_reason(args):
    """Why the `git push` words args may not run, or None. A lease push passes only when each refspec names its
    branch literally and none is main or master; a bare refspec such as `HEAD` pushes a branch the words do not show."""
    bare = lease = False
    positional, k = [], 0
    while k < len(args):
        arg, k = args[k], k + 1
        if arg == "--":
            positional += args[k:]
            break
        name = arg.split("=", 1)[0]
        # A bundle of short flags such as -uf counts too.
        if name in FORCE_FLAGS or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", arg):
            bare = True
        elif name in LEASE_FLAGS:
            lease = True
        elif name in PUSH_VALUE_OPTIONS and "=" not in arg:
            k += 1
        elif not arg.startswith("-"):
            positional.append(arg)
    refspecs = positional[1:]
    if bare or any(spec.startswith("+") for spec in refspecs):
        return ("`-f`, `--force`, and a `+` refspec overwrite whatever the remote branch holds. Push with "
                "`git push --force-with-lease origin HEAD:<branch>`, which refuses when the remote moved. If Omer asked "
                "for this push, he runs it himself with `! git push ...`.")
    if not lease:
        return None
    targets = [spec.rpartition(":")[2].removeprefix("refs/heads/") for spec in refspecs]
    if not targets or any(t in DEFAULT_BRANCHES or t in ("", "HEAD") or re.search(r"[$`*]", t) for t in targets):
        return ("A force-push may not rewrite main or master, and this one names no branch, names it through a "
                "variable, or names main or master. Name the branch: `git push --force-with-lease origin "
                "HEAD:<branch>`. On main, add commits on top and undo with `git revert`; if Omer asked for this "
                "push, he runs it himself with `! git push ...`.")
    return None


def _option_values(args, long_name, short, letters):
    """Every value that args give to `--long_name` or the short letter, as `--x v`, `--x=v`, `-x v`, `-xv`, `-x=v`, and
    `-x` last in a bundle such as `-dx v`. letters are the short options of the command that take a value. Words after
    `--` are not options."""
    values, k = [], 0
    while k < len(args):
        arg, k = args[k], k + 1
        if arg == "--":
            break
        if arg.startswith("--"):
            name, equals, value = arg.partition("=")
            if name == "--" + long_name:
                if equals:
                    values.append(value)
                elif k < len(args):
                    values.append(args[k])
                    k += 1
        elif arg.startswith("-"):
            for j, letter in enumerate(arg[1:], 2):
                if letter in letters:
                    rest = arg[j:]
                    if rest or k < len(args):
                        value = rest[1:] if rest.startswith("=") else rest or args[k]
                        k += 0 if rest else 1
                        if letter == short:
                            values.append(value)
                    break
    return values


def _has_label(values):
    return LABEL in {name.strip().lower() for value in values for name in value.split(",")}


def _writes_label_through_api(args, call):
    """Whether the `gh api` call with args (uncut) sends the label with a request that writes labels. The body may
    come from a field or from `--input`: a file, or stdin. Stdin text that this command writes shows in the raw
    command; stdin from a file shows in the files that any command of the call names, such as a `<` redirect or a
    `cat file |`."""
    fields = _option_values(args, "field", "F", API_VALUES) + _option_values(args, "raw-field", "f", API_VALUES)
    inputs = _option_values(args, "input", None, API_VALUES)
    methods = _option_values(args, "method", "X", API_VALUES)
    method = methods[-1].upper() if methods else "POST" if fields or inputs else "GET"
    if method not in ("POST", "PUT", "PATCH") or not any(
            len(word) <= 512 and LABEL_PATH.search(word.split("?", 1)[0]) for word in args):
        return False
    if _has_label([f.partition("=")[2] for f in fields]):
        return True
    if not inputs:
        return False
    paths = [path for name in inputs for path in call.existing_files(name)]
    if any(name == "-" or name.startswith(("/dev/", "<(")) for name in inputs):
        paths += [path for command in call.commands for path in call.named_files(command)]
    return LABEL in call.command.lower() or any(LABEL in call.read(path, INPUT_CAP).lower() for path in paths)


def _sets_upstream_without_branch(args):
    """Whether the `git branch` words args set or unset an upstream and name no branch, so git changes the
    checked-out one."""
    sets, positional, k = False, 0, 0
    while k < len(args):
        arg, k = args[k], k + 1
        if arg == "--":
            positional += len(args) - k
            break
        name, equals, _ = arg.partition("=")
        if arg.startswith("--"):
            # git takes an unambiguous prefix of a long option; shorter than these, the prefix names other options too.
            if len(name) >= len("--set-upstream-") and "--set-upstream-to".startswith(name):
                sets = True
                k += 0 if equals else 1
            elif name == "--set-upstream" or (len(name) >= len("--unset") and "--unset-upstream".startswith(name)):
                sets = True
            elif name in BRANCH_VALUE_OPTIONS:
                k += 0 if equals else 1
        elif arg.startswith("-") and len(arg) > 1:
            if "u" in arg[1:]:
                sets = True
                k += 0 if arg.partition("u")[2] else 1
        else:
            positional += 1
    return sets and positional == 0


def _overrides_hooks_path(options):
    """Whether the global options before the subcommand set `core.hooksPath`, as `-c` or `--config-env` does."""
    return any(name in ("-c", "--config-env") and (value or "").split("=", 1)[0].lower() == "core.hookspath"
               for name, value in options)


def _skips_hooks(command, args):
    """Whether the words args after the git subcommand command skip a hook: `--no-verify` or a prefix of it that git
    reads as it, or `-n` alone or in a bundle of `git commit` short options. Words after `--` are paths."""
    for arg in args:
        if arg == "--":
            break
        name = arg.partition("=")[0]
        if len(name) >= len("--no-veri") and "--no-verify".startswith(name):
            return True
        if command == "commit" and arg.startswith("-") and not arg.startswith("--"):
            for letter in arg[1:]:
                if letter == "n":
                    return True
                if letter in COMMIT_VALUES or letter in COMMIT_ATTACHED:
                    break
    return False


def _git_reason(git):
    verb = git.args[:1]
    if verb and verb[0] in VERIFY_COMMANDS and (_overrides_hooks_path(git.options) or _skips_hooks(verb[0], git.args[1:])):
        return ("This skips the repository's git hooks, which the shared rules allow only when Omer asks. Run the "
                "command without `--no-verify`, `-n`, or a `core.hooksPath` override, and fix what the hook reports; "
                "in a fresh worktree run the repository's install first. If Omer asked for the skip, he runs it "
                "himself with `! git ...`.")
    if verb == ["push"] and (reason := _force_push_reason(git.args[1:])):
        return reason
    if verb == ["branch"] and _sets_upstream_without_branch(git.args[1:]):
        if any("--unset-upstream".startswith(arg.partition("=")[0]) for arg in git.args[1:] if arg.startswith("--unset")):
            return "Name the branch: `git branch --unset-upstream <branch>`."
        return "Name the branch: `git branch -u <upstream> <branch>`."
    return None


def _pushes_after_unchecked_commit(call):
    """Whether a `git push` follows a `git commit` in the call's own commands with a separator other than `&&` between
    them, so the push runs when the commit or its hook fails."""
    chained = None
    for command in call.top_level:
        if command.empty:
            continue
        verb = command.git.args[:1] if command.git else None
        if verb == ["push"] and chained is False:
            return True
        if verb == ["commit"]:
            chained = command.connector_after == "&&"
        elif chained is not None:
            # A pipe right after the commit hides its exit status; a later one sits inside the `&&` chain.
            chained = chained and command.connector_after in ("&&", "|")
    return False


def _gh_reason(args, call):
    group, verb, rest = _gh_words(args)
    if group == "pr" and verb == "merge" and shutil.which("pr-land"):
        return ("Merge with `pr-land <n>` from the main checkout: it waits for the checks, merges with "
                "squash, and removes the worktree and branches.")
    rest = [text for word in rest for text in (call.expand(word) if "$" in word else [word])]
    if ((group in ("pr", "issue") and verb == "edit" and _has_label(_option_values(rest, "add-label", None, EDIT_VALUES)))
            or (group == "pr" and verb == "create" and _has_label(_option_values(rest, "label", "l", CREATE_VALUES)))
            or (group == "api" and _writes_label_through_api(rest, call))):
        return ("The `automerge` label merges the PR through the merge controller. Land with `pr-land <n>`; "
                "Omer can add it himself with `!`.")
    return None


def _push_merge_reason(call):
    if _pushes_after_unchecked_commit(call):
        return COMMIT_THEN_PUSH_REASON
    for command in call.commands:
        if command.git:
            reason = _git_reason(command.git)
        elif command.program == "gh":
            reason = _gh_reason(command.args_full, call)
        else:
            continue
        if reason:
            return reason
    return None


def _default_branch(directory, deadline):
    head = git_output(directory, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", deadline=deadline)
    if head and "/" in head:
        return head.split("/", 1)[1]
    main = git_output(directory, "rev-parse", "--verify", "--quiet", "refs/heads/main", deadline=deadline)
    return "main" if main is not None else "master"


def _moves_head(directory, sub, args, deadline):
    flags = {a for a in args if a.startswith("-")}
    names = [a for a in args if not a.startswith("-") or a == "-"]
    if sub == "reset":
        return bool(flags & HARD_RESETS)
    if sub not in ("checkout", "switch"):
        return False
    if flags & MOVING:
        return True
    if sub == "checkout" and "--" in args:
        return False
    if not names:
        return sub == "switch"
    if names == [_default_branch(directory, deadline)]:
        return False
    if sub == "switch":
        return True
    # `git checkout <path>` restores a file; only a name that is a revision moves HEAD.
    return git_output(directory, "rev-parse", "--verify", "--quiet", f"{names[0]}^{{commit}}", deadline=deadline) is not None


def _main_checkout_reason(call):
    for commands in (call.top_level, call.commands):
        for command in commands:
            directory = command.git_directory
            if command.git and command.git.args and directory is not None \
                    and _moves_head(directory, command.git.args[0], command.git.args[1:], call.deadline) \
                    and is_shared_checkout(directory, call.deadline):
                return CHECKOUT_REASON
    return None


def _worktree_path(args):
    """The path argument of the `git worktree add` words args, which start at the git subcommand, or None when args
    is another git command."""
    if args[:2] != ["worktree", "add"]:
        return None
    k = 2
    while k < len(args):
        arg = args[k]
        if arg == "--":
            return args[k + 1] if k + 1 < len(args) else None
        if arg in ADD_VALUE_OPTIONS or (arg[:1] == "-" and arg[1:2] != "-" and len(arg) > 2 and arg[-1] in "bB"):
            k += 2
        elif arg.startswith("-"):
            k += 1
        else:
            return arg
    return None


def _outside(path, cwd):
    if path.startswith(("$HOME/", "${HOME}/")):
        path = os.path.expanduser("~") + path[path.index("/"):]
    path = os.path.expanduser(path)
    if "$" in path or "`" in path:
        return False
    full = os.path.normpath(os.path.join(cwd, path))
    return not full.startswith(WORKTREE_ROOT + os.sep)


def _worktree_reason(call):
    if "worktree" not in call.command:
        return None
    for command in call.commands:
        path = _worktree_path(command.git.args) if command.git else None
        if path and _outside(path, call.cwd):
            return WORKTREE_REASON
    return None


def _body_files(call):
    files = []
    for command in call.commands:
        if command.program != "gh":
            continue
        group, verb, rest = _gh_words(command.args_full)
        rest = [text for word in rest for text in (call.expand(word) if "$" in word else [word])]
        if group in ("pr", "issue") and verb in POST_VALUES:
            names = _option_values(rest, "body-file", "F", POST_VALUES[verb])
        elif group == "api":
            fields = _option_values(rest, "field", "F", API_VALUES)
            names = _option_values(rest, "input", None, API_VALUES) + [f.partition("=@")[2] for f in fields if "=@" in f]
        else:
            continue
        files += [path for name in names if name != "-" for path in call.existing_files(name)]
    return files


def _without_mktemp_templates(call):
    text, kept, last = call.command, [], 0
    for command in sorted((c for c in call.commands if c.program == "mktemp"), key=lambda c: c.span):
        start, end = command.span
        if start < last:
            continue
        kept += [text[last:start], MKTEMP_TEMPLATE.sub("", text[start:end])]
        last = end
    return "".join(kept) + text[last:]


def _placeholder_reason(call):
    if not POSTING.search(call.command):
        return None
    texts = [_without_mktemp_templates(call)]
    texts += [call.read(path, PLACEHOLDER_CAP) for path in _body_files(call)]
    for text in texts:
        match = PLACEHOLDER.search(text)
        if match:
            return (f"GitHub post text holds a placeholder ({match.group(0)!r}). "
                    "Replace it with the real value before posting.")
    return None


CHECKS = (_placeholder_reason, _push_merge_reason, _main_checkout_reason, _worktree_reason)
