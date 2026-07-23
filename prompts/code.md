You are implementing a GitHub issue in an existing repository.

Repository: ${REPO_OWNER}/${REPO_NAME}
Local path: ${REPO_PATH}
Current branch: ${WORK_BRANCH}
Base branch: ${BASE_BRANCH}

Issue #${ISSUE_NUM}: ${ISSUE_TITLE}
${ISSUE_URL}

Body:
${ISSUE_BODY}

The plan for this change is at: ${PLAN_MD_PATH}

Your task:
1. Read ${REPO_PATH}/CLAUDE.md for project context.
2. Read ${PLAN_MD_PATH} and follow it.
3. Implement the change. Create/edit files as needed inside ${REPO_PATH}.
4. If tests are part of the plan, add them.

Rules:
- Stay inside ${REPO_PATH}. Do not touch anything outside.
- Do NOT run `git commit` or `git push` — the wrapper script commits.
- Do NOT create files outside the plan's scope.
- If the plan is impossible or contains a mistake, stop early and explain why in your final message instead of pushing broken code.

When done, print a one-paragraph summary of what changed.
