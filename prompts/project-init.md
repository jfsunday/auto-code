You are initializing the project context for a new repository.

Repository: ${REPO_OWNER}/${REPO_NAME}
Local path: ${REPO_PATH}

There is currently no CLAUDE.md in this repo. The following GitHub issue explains what this repo is supposed to become:

Issue #${ISSUE_NUM}: ${ISSUE_TITLE}
${ISSUE_URL}

Body:
${ISSUE_BODY}

Your task:
1. Read any existing files in ${REPO_PATH} to understand what is already there (probably just a README).
2. Write a file at ${REPO_PATH}/CLAUDE.md containing the project context that future automated coding sessions should use as ground truth. Include, where inferable:
   - One-paragraph project purpose
   - Target tech stack / language (if implied by the issue)
   - Directory layout (planned)
   - Coding conventions (naming, formatting)
   - How to run and test (once code exists)
   - What NOT to do (out-of-scope areas)

Keep it short — around 40-80 lines. It will grow over time as more issues are processed.

Do not create any other files. Do not commit — the wrapper script will handle git operations. When done, print a one-sentence confirmation.
