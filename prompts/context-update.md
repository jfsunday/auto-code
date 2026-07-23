You just completed work on issue #${ISSUE_NUM} in ${REPO_OWNER}/${REPO_NAME}.

The project context lives at ${REPO_PATH}/CLAUDE.md. Consider whether this change teaches something durable about the project that future automated sessions should know:

- New commands to run (build, test, lint) that didn't exist before
- New directory / module conventions the change established
- A previously-implicit constraint that's now been made explicit
- A "how we do X" pattern worth codifying

Your task:
1. Read ${REPO_PATH}/CLAUDE.md.
2. Read the diff of the work just merged into this branch: `git diff ${BASE_BRANCH}...HEAD` in ${REPO_PATH}.
3. Decide: does CLAUDE.md need an update?
   - If YES: edit ${REPO_PATH}/CLAUDE.md with tight, durable additions. Do not restate what was already there. Do not add task-specific noise.
   - If NO: change nothing.

Do NOT commit. When done, the VERY LAST line of your final message MUST be one of exactly:

STATUS: UPDATED
STATUS: NO_CHANGE
