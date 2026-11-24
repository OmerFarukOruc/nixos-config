"""Checks on calls that run git or gh: a push that rewrites main or skips the repository's hooks, a `git add` that
stages everything (a dry run, `-n` or `--dry-run` without a later `--no-dry-run`, stages nothing and passes unless
`-e`, `-p` or `-i` makes git stage anyway) or a `git commit` without a pathspec, a merge or label that bypasses
`pr-land`, a HEAD move in a repository's main checkout, a `git worktree add` outside the worktrees folder, and a GitHub
post that still holds a placeholder.

Sessions share a checkout's index, so a commit without a pathspec can take files another session staged. A commit
that git refuses to make partial, the one that concludes a merge, cherry-pick or revert, passes, and so does a dry run
(`--dry-run`, `--short`, `--porcelain`, `--long`), unless a later `--no-<option>` cancels it. A commit with `-i` or
`--include` is refused, `--amend` included. In a repository's main checkout, a `git add -u` (`--update`) without a
pathspec is refused, because it stages the tracked edits of every session working there, and so is a `git commit
--amend` without a pathspec or with one that covers the whole tree, because it takes whatever the shared index holds;
`--amend --only` without a path and `--amend --pathspec-from-file` pass. A linked worktree's index belongs to one
session, so both pass there, and so does a call whose directory the checks cannot follow: a wrapper that moves it
(`env -C`, `direnv exec <dir>`), `pushd`, or a `GIT_DIR` or `GIT_WORK_TREE` setting.

Sessions share a repository's main checkout, so a `git checkout <rev>`, `git switch`, or `git reset --hard` there
changes the files under every other session working in it. A linked worktree is a session's own, and so are the
default branch, a path restore (`git checkout -- <path>` or `git checkout <path>`), a soft or mixed reset, and a
clone under /tmp or $TMPDIR. A checkout is the main one when its git dir is the common git dir.

The shared rules let an agent rebase a published branch, and `--force-with-lease` refuses to push when the remote
branch moved since the last fetch, so a lease push to a branch the command names passes. The label check does not
read a label that comes from a file inside a value (`-F 'labels[]=@file'`), from `$(cat file)`, or from a pipe into
`xargs`; it does read an `--input` file.

Every check but the commit pathspec check fails open: a command that does not parse, a directory git cannot read, or a
file that cannot be read lets the call through. A commit without a pathspec whose repository git cannot read is refused,
because the hook cannot tell whether it concludes a merge, cherry-pick or revert. The placeholder check also searches
the raw command text, so a command that does not parse still gets that search.
"""
import dataclasses
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
FORCE_FLAGS = {"--force"}
LEASE_FLAGS = {"--force-with-lease", "--force-if-includes"}
DEFAULT_BRANCHES = {"main", "master"}
# `git push` options that may take the next word as their value.
PUSH_VALUE_OPTIONS = {"--push-option", "--repo", "--receive-pack", "--exec"}
PUSH_VALUE_LETTERS = "o"
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
ADD_VALUE_OPTIONS = {"--reason"}
HEAD_MOVING_VERBS = {"commit", "rebase", "merge", "cherry-pick", "am", "revert"}
SHARED_INDEX = "Sessions share the checkout's index, so this takes files another session left there."
STAGE_ALL_REASON = ("Stage the paths you changed by name: `git add -- <path>...`, with no `-A`, `--all`, `.`, `:/` or "
                    f"other pathspec that covers the whole tree. {SHARED_INDEX}")
COMMIT_ALL_REASON = ("Stage new files with `git add -- <path>...`, then commit by name: `git commit -m <msg> -- "
                     f"<path>...`, without `-a`. {SHARED_INDEX}")
UPDATE_ALL_REASON = ("In a repository's main checkout, name the paths you changed: `git add -u -- <path>...`. "
                     "Sessions share the checkout's files, so this stages tracked edits another session made.")
AMEND_REASON = ("In a repository's main checkout, amend with your paths named: `git commit --amend -m <msg> -- "
                "<path>...`, or `git commit --amend --only` to change only the message. "
                f"{SHARED_INDEX}")
PATHSPEC_REASON = ("Commit only your paths, named after `--`: `git commit -m <msg> -- <path>...`, with no `-i` and no "
                   f"pathspec that covers the whole tree. {SHARED_INDEX}")
UNREADABLE_REASON = ("git could not read the repository this commit targets, so the hook cannot tell whether it "
                     "concludes a merge, cherry-pick or revert. Commit with `-- <path>...`, or check the `-C` path.")
CHAINED_SEQUENCER_REASON = ("Run the commit that concludes a merge, cherry-pick or revert in its own call, because "
                            "the git command before it in this call changes what that commit takes.")
DIRECTORY_SETTINGS = re.compile(r"\bpushd\b|\bGIT_(?:DIR|WORK_TREE)=")
SEQUENCER_HEADS = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")
COMMIT_SHORT_NAMES = {"--all": "a", "--include": "i", "--only": "o"}
COMMIT_LONG_OPTIONS = {
    "--message": True, "--file": True, "--reuse-message": True, "--reedit-message": True, "--template": True,
    "--author": True, "--date": True, "--cleanup": True, "--fixup": True, "--squash": True, "--trailer": True,
    "--pathspec-from-file": True, "--all": False, "--amend": False, "--include": False, "--only": False,
    "--interactive": False, "--patch": False, "--quiet": False, "--verbose": False, "--dry-run": False,
    "--short": False, "--branch": False, "--porcelain": False, "--long": False, "--null": False, "--signoff": False,
    "--no-verify": False, "--verify": False, "--allow-empty": False, "--allow-empty-message": False,
    "--no-edit": False, "--no-verbose": False, "--edit": False, "--reset-author": False, "--status": False,
    "--no-status": False,
    "--no-post-rewrite": False, "--untracked-files": False, "--gpg-sign": False, "--no-gpg-sign": False,
    "--pathspec-file-nul": False,
}
COMMIT_THEN_PUSH_REASON = (
    "This pushes even when the `git commit`, `rebase`, `merge`, `cherry-pick`, `am` or `revert` before it fails, "
    "and then publishes whatever HEAD already held: Omer's unpushed commits, or the half-finished state of a "
    "stopped rebase, which closes a PR whose head then equals main. Join the two with `&&`, or push in a later "
    "call after the first exits 0 and `git status` shows no rebase in progress."
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


def _short_bundle(word, values, attached=""):
    """The letters of the short-option bundle word, such as `-dx`, up to the first letter that takes a value, the text
    after that letter or None when no letter takes one, and whether the value is the next word: a letter in values
    takes that text, or the next word when the text is empty; a letter in attached takes only that text."""
    for at, letter in enumerate(word[1:], 2):
        if letter in values or letter in attached:
            rest = word[at:]
            return word[1:at], rest, letter in values and not rest
    return word[1:], None, False


def _short_letters(args, values):
    """The short options of the words args before `--`, each as `-<letter>`, reading bundles such as `-fb`."""
    words = args[:args.index("--")] if "--" in args else args
    return {"-" + letter for word in words if word.startswith("-") and not word.startswith("--") and len(word) > 1
            for letter in _short_bundle(word, values)[0]}


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
        if arg.startswith("-") and not arg.startswith("--") and len(arg) > 1:
            letters, _, takes_next = _short_bundle(arg, PUSH_VALUE_LETTERS)
            bare = bare or "f" in letters
            k += takes_next
        elif name in FORCE_FLAGS:
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
            bundle, rest, _ = _short_bundle(arg, letters)
            if rest is not None and (rest or k < len(args)):
                value = rest[1:] if rest.startswith("=") else rest or args[k]
                k += 0 if rest else 1
                if bundle[-1] == short:
                    values.append(value)
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
            _, rest, takes_next = _short_bundle(arg, "u")
            if rest is not None:
                sets = True
                k += takes_next
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
    words = _commit_words(args)[0] if command == "commit" else args[:args.index("--")] if "--" in args else args
    if "n" in words and command == "commit":
        return True
    return any(len(name) >= len("--no-veri") and "--no-verify".startswith(name)
               for name in (word.partition("=")[0] for word in words))


def _long_option(word):
    """The `git commit` long option that word names exactly or as an unambiguous prefix, or None."""
    name = word.partition("=")[0]
    if name in COMMIT_LONG_OPTIONS:
        return name
    matches = [option for option in COMMIT_LONG_OPTIONS if option.startswith(name)]
    return matches[0] if len(name) > 3 and len(matches) == 1 else None


def _commit_words(args):
    """The options of the `git commit` words args, as long names and short letters, and the words after `--`, or None
    without `--`. A value option takes the next word whatever it holds, so `-m --amend` is a message."""
    options, k = set(), 0
    while k < len(args):
        word = args[k]
        if word == "--":
            return options, args[k + 1:]
        if word.startswith("--"):
            option = _long_option(word)
            negated = _long_option("--" + word[len("--no-"):]) if option is None and word.startswith("--no-") else None
            if negated:
                options.discard(negated)
                options.discard(COMMIT_SHORT_NAMES.get(negated))
            else:
                options.add(option or word)
            k += bool(COMMIT_LONG_OPTIONS.get(option) and "=" not in word)
        elif word.startswith("-") and len(word) > 1:
            letters, _, takes_next = _short_bundle(word, COMMIT_VALUES, COMMIT_ATTACHED)
            options.update(letters)
            k += takes_next
        k += 1
    return options, None


def _whole_tree(path):
    """Whether the pathspec path covers the whole tree or everything but a part of it: `.`, `./`, `..`, `:`, `:/`,
    `:(top)`, a path whose components each match every name, such as `*`, `**`, `**/*` or `?*`, or an exclusion such as
    `:!x`."""
    rest = path
    if rest.startswith(":"):
        magic = re.match(r":(\([^)]*\)|[/!^]*:?)", rest)
        if any(mark in magic.group(1) for mark in ("!", "^", "exclude")):
            return True
        rest = rest[magic.end():]
    return all(part in (".", "..") or ("*" in part and set(part) <= {"*", "?"})
               for part in os.path.normpath(rest or ".").split("/"))


def _abbreviates(name, option, shortest):
    """Whether the long option word name is option or an abbreviation of it that git reads, at least shortest long."""
    return len(name) >= len(shortest) and option.startswith(name)


@dataclasses.dataclass
class AddWords:
    """The `git add` options that the index checks read, in the order git applies them, and the pathspecs."""
    all: bool = False
    update: bool = False
    dry_run: bool = False
    interactive: bool = False
    from_file: bool = False
    paths: list = dataclasses.field(default_factory=list)


def _add_words(args):
    words, k, after_dashes = AddWords(), 0, False
    while k < len(args):
        word = args[k]
        name, eq, _ = word.partition("=")
        if after_dashes or not word.startswith("-"):
            words.paths.append(word)
        elif word in ("--", "--end-of-options"):
            after_dashes = True
        elif _abbreviates(name, "--all", "--al"):
            words.all = True
        elif _abbreviates(name, "--update", "--up"):
            words.update = True
        elif _abbreviates(name, "--no-update", "--no-u"):
            words.update = False
        elif _abbreviates(name, "--dry-run", "--d"):
            words.dry_run = True
        elif _abbreviates(name, "--no-dry-run", "--no-d"):
            words.dry_run = False
        elif any(_abbreviates(name, option, option[:4]) for option in ("--edit", "--patch", "--interactive")):
            words.interactive = True
        elif _abbreviates(name, "--pathspec-from-file", "--pathspec-fr"):
            words.from_file = True
            k += not eq
        elif _abbreviates(name, "--chmod", "--ch"):
            k += not eq
        elif not word.startswith("--"):
            for letter in word[1:]:
                words.all = words.all or letter == "A"
                words.update = words.update or letter == "u"
                words.dry_run = words.dry_run or letter == "n"
                words.interactive = words.interactive or letter in "epi"
        k += 1
    return words


def _add_stages_all(words):
    """Whether `git add` stages every change: `-A` alone or in a bundle, `--all` or a prefix git reads as it, or a
    pathspec that covers the whole tree."""
    return words.all or any(_whole_tree(path) for path in words.paths)


def _add_updates_all(words):
    """Whether `git add` updates every tracked file: `-u` or `--update` with no pathspec and no
    `--pathspec-from-file`."""
    return words.update and not words.from_file and not words.paths


def _amends_all(options, paths):
    """Whether the `git commit --amend` options and paths take the whole index: a pathspec that covers the whole tree,
    or no pathspec without `--only` and without `--pathspec-from-file`."""
    if paths and any(_whole_tree(p) for p in paths):
        return True
    return not paths and not options & {"--only", "o", "--pathspec-from-file"}


def _directory_unknown(command, text):
    """Whether the directory a git command acts on may differ from the one the checks read: a wrapper that moves it
    (`env -C`, `direnv exec <dir>`), a `pushd`, or a `GIT_DIR` or `GIT_WORK_TREE` setting in the call."""
    if DIRECTORY_SETTINGS.search(text):
        return True
    lead = command.full[:len(command.full) - len(command.invocation)]
    for k, word in enumerate(lead):
        if word == "env" and any(w in ("-C", "--chdir") or w.startswith(("-C", "--chdir=")) for w in lead[k + 1:]):
            return True
        if word == "direnv" and lead[k + 1:k + 2] == ["exec"] and lead[k + 2:k + 3] not in ([], ["."], ["./"]):
            return True
    return False


def _in_shared_checkout(git, directory, deadline, unknown):
    repository = _repository_directory(git, directory)
    return not unknown and repository is not None and is_shared_checkout(repository, deadline)


def _concludes_sequencer(directory, deadline):
    """Whether the repository at directory has a merge, cherry-pick or revert waiting for its commit, or None when git
    cannot read it."""
    git_dir = directory and git_output(directory, "rev-parse", "--path-format=absolute", "--git-dir", deadline=deadline)
    if not git_dir:
        return None
    return any(os.path.exists(os.path.join(git_dir, name)) for name in SEQUENCER_HEADS)


def _repository_directory(git, directory):
    """The directory to ask git about: the `--git-dir` the command names, against the directory it runs in."""
    named = [value for option, value in git.options if option == "--git-dir" and value]
    return os.path.join(directory, named[-1]) if named and directory else directory


def _index_reason(git, directory, deadline, after_head_move, unknown):
    verb = git.args[:1]
    if verb in (["add"], ["stage"]):
        words = _add_words(git.args[1:])
        if words.dry_run and not words.interactive:
            return None
        if _add_stages_all(words):
            return STAGE_ALL_REASON
        if _add_updates_all(words) and _in_shared_checkout(git, directory, deadline, unknown):
            return UPDATE_ALL_REASON
        return None
    if verb != ["commit"]:
        return None
    options, paths = _commit_words(git.args[1:])
    if options & {"--dry-run", "--short", "--porcelain", "--long"}:
        return None
    if options & {"--all", "a"}:
        return COMMIT_ALL_REASON
    if options & {"--include", "i"}:
        return PATHSPEC_REASON
    if "--amend" in options:
        return AMEND_REASON if _amends_all(options, paths) and _in_shared_checkout(git, directory, deadline, unknown) \
            else None
    if "--pathspec-from-file" in options:
        return None
    if paths and not any(_whole_tree(p) for p in paths):
        return None
    if paths is not None:
        return PATHSPEC_REASON
    concludes = _concludes_sequencer(_repository_directory(git, directory), deadline)
    if concludes is None:
        return UNREADABLE_REASON
    if not concludes:
        return PATHSPEC_REASON
    return CHAINED_SEQUENCER_REASON if after_head_move else None


def _index_call_reason(call):
    """The reason to refuse a `git add` or `git commit` of the call, reading each top-level command's directory with
    its variables resolved."""
    resolved = {command.span: command for command in call.top_level if command.git}
    head_moved, seen = False, set()
    for command in call.commands:
        if not command.git or command.span in seen:
            continue
        seen.add(command.span)
        own = resolved.get(command.span, command)
        unknown = _directory_unknown(command, call.command)
        if reason := _index_reason(command.git, own.git_directory, call.deadline, head_moved, unknown):
            return reason
        head_moved = head_moved or command.git.args[:1] and command.git.args[0] in HEAD_MOVING_VERBS
    return None


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
        if verb and verb[0] in HEAD_MOVING_VERBS:
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
    flags = {a for a in args if a.startswith("--")} | _short_letters(args, "bBcC")
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
        if arg in ADD_VALUE_OPTIONS or (arg[:1] == "-" and arg[1:2] != "-" and _short_bundle(arg, "bB")[2]):
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


CHECKS = (_placeholder_reason, _push_merge_reason, _index_call_reason, _main_checkout_reason, _worktree_reason)
