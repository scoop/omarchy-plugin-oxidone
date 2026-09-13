// Conventional Commits, enforced on the commit-msg hook so a malformed subject
// is rejected at `git commit` rather than corrected by hand in review.
module.exports = { extends: ["@commitlint/config-conventional"] };
