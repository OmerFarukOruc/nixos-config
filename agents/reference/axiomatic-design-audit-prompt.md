# Axiomatic Design coupling audit of a repository

You audit how coupled one software repository is, with Nam P. Suh's Axiomatic Design. You read the repository, build a design matrix with evidence, classify the matrix by a check you run step by step, and report. You change nothing in the repository. Work through the steps in order and send one report at the end. Decide every open choice yourself with the defaults below, and record each choice in the report.

```
Repository: {{REPOSITORY_LINK}}
Revision:   {{REVISION: a branch, tag or commit; "default branch" when not given}}
```

Steps: 1 read the repository, 2 extract the functional requirements and constraints, 3 choose the design parameters, 4 fill the design matrix and prove each mark, 5 classify the matrix by the check, 6 go one level down in the worst groups, 7 name the hotspots and the changes, 8 write the report from the template, then the checks under "Before you send".

## Terms

Use these terms with exactly these meanings. They come from Suh, *Axiomatic Design: Advances and Applications*, chapter 1, as MIT course 2.882 publishes it: https://web.mit.edu/2.882/www/chapter1/chapter1.htm (the text around equations 1.3 to 1.5, and Theorems 1 and 3).

- **Functional requirement (FR)**: one thing the system must do. Suh: "a minimum set of independent requirements that completely characterizes the functional needs". An FR says what, and names no solution. Write "Tell a user when a case changes", and leave "Send email through the mail queue" for the design parameter.
- **Design parameter (DP)**: the part of the design that exists to satisfy one FR. In a repository, a DP is code or config you can point at: a directory, a package, a module, a set of config files, or the config of an outside service. When one file holds several FRs, a DP can be a class, a group of functions or a section of a config file.
- **Constraint (C)**: a bound on acceptable solutions, such as a language, a platform, a cost limit, a compatibility rule or "no schema files". A constraint limits every DP and gets no row in the matrix.
- **Design matrix**: one row per FR, one column per DP. Row i, column j holds a mark when a change to DP j can change whether FR i is still met.
- **Independence Axiom (Axiom 1)**: "Maintain the independence of the functional requirements."
- **Uncoupled design**: the matrix is diagonal. Each FR depends only on its own DP.
- **Decoupled design**: the matrix is triangular, or becomes triangular after you reorder rows and columns. The Independence Axiom holds "if and only if the DPs are changed in a proper sequence". Upper and lower triangular are the same case, because reversing the order turns one into the other.
- **Coupled design**: any other matrix. It violates the Independence Axiom.
- **Redundant design**: more DPs than FRs (Theorem 3). This audit gives each FR one DP, so it does not model that case. With fewer DPs than FRs, the design is coupled or some FR cannot be met (Theorem 1); the audit shows that case as two FRs with the same DP.

A triangular matrix with at least one off-diagonal mark is decoupled, never "uncoupled". Some summaries of the method mix the two words; keep them apart in everything you write.

## Step 1: Read the repository

1. Open the repository at the revision above. When you read a clone, fetch first. Resolve the revision to one commit hash, and record it with how you read the repository (a clone, a file browser, uploaded files). When the way you read it shows no commit hash, record the date and say that the hash is missing.
2. List every top-level file and directory.
3. Read what states the purpose: the README, the docs folder, a spec, user stories, the changelog, the public API or CLI help, and the test names. Then read the code and config: entry points, the package layout, build files, deploy and CI files.

When you cannot open the files, stop here and say what failed. An audit written from memory of a project is worth nothing, so send no matrix in that case. You need not run the repository's code or tests, and the report says whether you did. Step 4 says which tool proves a mark.

Done when: you can name the commit hash, or say why you have none, and you have the full top-level list.

## Step 2: Extract the functional requirements and the constraints

1. Write the top-level FRs: between 8 and 25, a guess at what one readable matrix holds, so a small repository may have fewer. Take them from what users and operators can do, in this order of trust: user stories or a spec, the README and docs, the public API or CLI, the tests. Include the operational functions the repository implements, such as build, test, deploy, monitoring and secrets, when it holds code or config for them. Product and operational FRs go into one matrix, and the verdict says which kind each coupled group holds.
2. Give each FR an ID (`FR1`, `FR2`, ...), one sentence that starts with a verb, and its source (file and line or heading).
3. Merge two FRs that state the same need into one. Split an FR that holds two functions a user could want separately.
4. List the constraints with their sources.
5. List each stated function that you leave out, with the reason, such as "no code in this repository implements it", or write "none".

Done when: every FR has a source, and every stated function is an FR or is on the left-out list.

## Step 3: Choose the design parameters

1. For each FR, name the one DP that exists to satisfy it, with its paths. `DPn` belongs to `FRn`.
2. Take DPs from the code and config as they are. When the docs describe a different structure, follow the code and record the disagreement for the report.
3. Place every top-level directory and file under one DP, or list it as not mapped with the reason (generated, vendored, editor config).
4. When one piece of code is the DP of two FRs, keep both FRs, give them the same DP, and record it: by Theorem 1 this is coupling. When code serves no FR, record it as unexplained.

Done when: the FR and DP lists have the same length, and the path coverage in item 3 is complete.

## Step 4: Fill the design matrix, one mark at a time

Set the diagonal first: FRn depends on DPn. Then decide each other cell (row i, column j) by asking: can a change to DP j change whether FR i is still met? Mark the cell only with evidence of one of these kinds:

- **Code**: a file of DP i imports, calls or extends something of DP j. A subclass depends on its base class. A base class that calls a method its subclasses override depends on them; any other base class does not.
- **Shared fact**: both DPs hold a copy of the same name, format, constant, state list, route or schema, and they must agree. Mark both directions when each side reads what the other writes, and one direction when only one side reads.
- **Platform**: DP i runs on, is built by, or is configured by DP j.
- **Check**: a test or check that belongs to DP i names a specific part of DP j, such as a symbol, a route, a file or a value.

Leave a cell empty when the only link is shared fate, which means two parts succeed or fail together without one reading the other: both are built by one command, sit in one repository, use the same language runtime, or are scanned by a tool that takes a whole folder, such as a linter, a formatter or a type checker.

Record for each mark: the row, the column, the kind, the evidence as `path:line` or `path` plus the symbol, and the proof. A mark is proven in one of these ways:

- **Code mark, when you can run commands**: a tool that reads compiled classes or the syntax tree found it, such as `jdeps -verbose:class -filter:none` together with a scan of the class files for classes named only in annotation arguments, which `jdeps` leaves out, or a Python `ast` walk of the imports. Record the command and where its output is.
- **Other kinds, or a language with no such tool**: a search command whose output shows both sides. Record the command and where its output is, and say that no stronger tool exists.
- **When you cannot run commands**: you opened the files of both sides and quote the line of each.

Every other mark carries the label `guess` and the command that would prove it. That holds when you did not open the file, when the mark rests on how a tool behaves and you did not check its documentation, and when a Code mark rests on reading alone although you could have run a class or syntax tool. For each document you read only in part, record the bytes you read and the bytes of the file. Search for the reverse direction of every mark before you leave it empty, because a pair of marks in both directions is what makes a design coupled.

Done when: every off-diagonal mark is proven or carries the label `guess` with the command that would prove it, and you have looked at both directions of every pair that has one mark.

## Step 5: Classify the matrix by the check

Run this check on the proven marks only: the class, the groups, the order and the flagged marks of the verdict come from this run. When you can execute code, write a short script for it and run it. Otherwise do it by hand and show each round. A judgement from the look of the matrix does not count, because the first order you wrote is arbitrary.

1. Count the proven off-diagonal marks. With zero and no `guess` mark, the design is **uncoupled**; go to step 7. With zero and at least one `guess` mark, the class is **not proven**; go to item 7.
2. Peel: make an empty list called `order`. Repeat: find an FR whose row has no mark in the column of any FR that is not yet in `order`, apart from its own column. Append it to `order`. Stop when no such FR is left.
3. When every FR is in `order`, the design is **decoupled**. `order` is the sequence in which the DPs must be set. Print the matrix with rows and columns in that sequence: every mark is on or below the diagonal.
4. When some FRs are left, the design is **coupled**. Find the coupled groups among all FRs: read "FR i depends on FR j" for each mark, and put two FRs in one group when each depends on the other, directly or through a chain of marks. By hand: start at one FR, follow its marks to collect every FR it reaches, and keep those that also reach it back. (These are the strongly connected components of the dependency graph.) A group has 2 or more FRs.
5. Build the final order: treat each coupled group as one block, and peel again. Inside each group, choose the order that leaves the fewest marks above the diagonal. For a group of up to 8 FRs, prove it is the fewest by trying the orders. For a larger group, give the best order you found and say it is not proven. When several FRs or orders tie, take the lowest FR number.
6. Print the matrix in the final order. Flag each mark above the diagonal. When the order of every group is proven to leave the fewest marks, these flagged marks are one smallest set of dependencies that stands between this design and a decoupled one, and another order with the same count can flag other marks. Otherwise they are the flagged marks of the best order found.
7. Run the check once more with the marks labelled `guess` included. Report whether the class or the groups change. That second result is a risk to name, and the verdict keeps the result of the proven marks.

Done when: the report can state the class, the final order, each coupled group, and the flagged marks, and the printed matrix agrees with all four.

## Step 6: Go one level down in the worst groups

The top level hides where inside a group the coupling sits. For each of the two coupled groups with the most FRs (and each group whose DPs hold more than a third of the code):

1. Take the modules inside the group's DPs as the lower-level DPs: packages, sub-directories, or files grouped by the function they serve. Say when a grouping is yours and the code does not show it.
2. Give each module the lower-level FR it serves.
3. Fill a sub-matrix by step 4 and classify it by step 5. For code marks, count the files behind each mark.
4. When the group has shared facts with more than one copy, add a table: the fact, each place that holds a copy, and the check that keeps the copies equal, or "no check".

Done when: each chosen group has a sub-matrix with its own class, order and flagged marks.

## Step 7: Name the hotspots and how to decouple them

For each coupled group, largest first:

1. Name the flagged marks with their evidence.
2. Say why each exists: a shared fact with several copies, a helper that sits in the wrong module, a module that serves several FRs, or a dependency that points the wrong way.
3. Give the change that removes the mark: give the shared fact one owner that both sides read, move the helper, split the module, or turn the dependency around behind an interface. When a mark should stay, write "keep" and the reason.
4. Give the cost in files touched, and name a constraint or a decision recorded in the files you read (docs, spec, changelog) that the change would break, or write "none found in the files".

Then list the first three changes in the order you would make them, each with the marks it removes. These are findings. Propose them and change nothing.

## Step 8: Write the report

Use this structure. Write in plain sentences, and define each term the first time you use it. The report has no length limit: keep one evidence line per mark.

```
# Axiomatic Design audit: <repository> at <commit hash, or the date when no hash is known>

## Verdict
One sentence: uncoupled, decoupled, coupled or not proven, from the proven marks, and where the worst coupling is.
Counts: FRs, proven off-diagonal marks, marks labelled guess, coupled groups with their sizes, flagged marks.
One sentence: whether the class or the groups change when the guess marks count.

## How I read the repository
Access method, commit, what I opened, what I did not open.

## Functional requirements and design parameters
| ID | FR | Source | DP | Paths |

## Constraints
| C | Source | DPs it limits most |

## Design matrix (final order)
Legend: ■ diagonal, X mark, ? mark that is a guess, ▲ added to a mark above the diagonal (X▲, ?▲).
The matrix, rows and columns in the final order, coupled groups named under it.

## Evidence
One line per proven off-diagonal mark: row, column, kind, evidence, the command and where its output is (or the two quoted lines).

## Unproven marks
One line per mark labelled guess: row, column, kind, why it is a guess, the command that would prove it.

## Check
The rounds of the peel, or the script and its output.

## Coupled groups and sub-matrices
Per group: its FRs, its flagged marks, its sub-matrix from step 6.

## Decoupling
Per group the changes of step 7, then the first three changes.

## Where the docs and the code disagree
Each disagreement with both locations. The audit followed the code.

## Not checked
Every limit of this audit.
```

Under "Not checked", always state these, each with what you did about it:

- The Information Axiom (Axiom 2, "Minimize the information content of the design") needs the probability that each DP meets its FR. A read of the code does not give it, so say that this audit covers the Independence Axiom only.
- The marks come from reading files. Say whether you ran the code, the tests or a dependency tool.
- The directories and files you did not open, each document you read only in part with the bytes read and the bytes of the file, and the number of marks labelled `guess`.
- The choice of FRs is a judgement. Another reader can choose other FRs and get another matrix. Name the two choices that changed your result most.

## Before you send

Check each line, and fix the report where one fails:

1. The words uncoupled, decoupled and coupled are used as the Terms section defines them.
2. The class in the verdict is the class the check of step 5 gave for the proven marks.
3. Every off-diagonal mark in the matrix has a line under Evidence or under Unproven marks, and every such line has a mark.
4. Every top-level path of the repository is under a DP or on the not-mapped list.
5. Every flagged mark appears under Decoupling with a change that removes it, or with "keep" and the reason.
6. Every number in the verdict equals a count of the matrix you printed.
