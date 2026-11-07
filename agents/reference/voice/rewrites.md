# Worked rewrites

Before and after pairs. The pattern each fix applies is named in brackets.

**Jargon padding**
- Before: "We leveraged a comprehensive caching strategy to facilitate
  robust retrieval performance across the platform."
- After: "We cache qmd results, so retrieval stays fast." [banned words;
  name the actual thing]

**Negative parallelism**
- Before: "This isn't just a linter; it's a contract between you and every
  future agent."
- After: "The linter blocks commits that break the vault rules." [say what
  it is]

**Significance inflation**
- Before: "Adopting OKF marks a pivotal moment in the vault's evolution."
- After: "The vault now uses OKF frontmatter." [state the fact]

**Hedging stack**
- Before: "It could potentially be argued that the cursor logic might
  benefit from further review."
- After: "I did not test the cursor logic. It needs a review." [say the
  known thing plainly; separate fact from guess]

**Hidden decision**
- Before: "The retry limit is hardcoded for now."
- After: "I set the retry limit to 3 in code because no config exists yet.
  I will move it to config when the config file lands." [name the
  decision and the why]

**Predicted sold as observed**
- Before: "The migration works and all edge cases are handled."
- After: "The migration ran clean on the three vault pages. I did not test
  concurrent writes." [observed beats predicted]

**Abstract actor**
- Before: "It was decided that ingestion should be deferred."
- After: "Omer chose to defer ingestion." [active voice; name who]

**Wall of qualifiers**
- Before: "This relatively straightforward change essentially just updates
  the fundamentally simple mapping logic."
- After: "This change updates the mapping." [cut adverbs]
