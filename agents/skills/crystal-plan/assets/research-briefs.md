# Research briefs

The planner follows these two research briefs in step 2 when a decision depends on
a third-party surface. A change inside repository code runs neither, writes `in-repo
only` with the imports checked under Sources, and settles from the code.

Run the docs discovery yourself, then a source check for every `docs do not settle`
line it yields. When a brief's docs would fill much of your context, fill its
angle-bracket inputs and send it as a subagent's whole prompt instead, and read the
repository while it runs; each brief is self-contained, so the subagent needs no skill
of its own.

Merge the results before settling decisions. A returned fact becomes a Sources line and
the Decision it supports. A `docs do not settle` line becomes a source check. A NOT
FOUND becomes an Open decision.

## Docs discovery (a third-party surface in the touch set)

```text
You research official documentation for an implementation plan. Answer from pages
you open in this run, never from memory.

Repository: <path>
Paths the change touches: <touch set, or the paths known so far>
Version pins: <lockfile, pyproject.toml, package.json, go.mod, or "read them from the repository">

1. From the code at those paths, list every third-party surface the change touches:
   imports outside the standard library, SDK and API calls, CLI tools, runtime
   features, and config keys. Read the pinned version of each from the version pins.
2. For each surface, open the official documentation for that pinned version: use
   context7 when you have it, otherwise the vendor's own docs site or repository.
   Read the section that governs how the change must call or configure the surface.
3. Return one block per surface in exactly this shape:

   <name> <pinned version>
   <URL>, <section> (official | community)
   Fact: "<at most two quoted lines that change a plan decision>"
   docs do not settle: <question the page is silent on>   (omit when none)

   Write NOT FOUND and the pages you checked when no official page exists for the
   surface. When the change touches no third-party surface, return
   "in-repo only" and the list of imports you checked.

Identifiers and credential types only; never copy a secret value, even from a vendor
example. Report what you could not find instead of a guess.
```

## Source check (when a decision rests on library or runtime internals)

Send one brief per question, including every `docs do not settle` line the docs
discovery returned.

```text
You read a dependency's source to settle one question for an implementation plan.
Answer from the code you open in this run, never from memory.

Dependency: <name> at <pinned version>
Question: <the behavior the plan depends on>
Calling code: <path::symbol in the repository>
Scratch directory: <path the harness names for clones>

1. Reuse a pinned checkout when one exists: <product repo>/.slim/clonedeps/repos/
   (listed in <product repo>/.slim/clonedeps.json), or another clone at that version.
   Otherwise clone read-only:
   git clone --depth 1 --branch <tag> <https URL> <scratch directory>/<name>
   Run no install, build, or test in the clone.
2. Read the code path that answers the question, starting from the symbol the
   calling code uses.
3. Return exactly this shape:

   <repository URL>@<tag or SHA>
   <path::symbol>, <path::symbol>
   Behavior: <one or two sentences of what the code does>
   Settles: <the plan decision this answers, or the assumption it breaks>

Identifiers and credential types only; never copy a secret value. Report what you
could not find instead of a guess.
```
