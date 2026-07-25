You are fixing issues found in a review of your own implementation.

Repository: ${REPO_OWNER}/${REPO_NAME}
Local path: ${REPO_PATH}
Current branch: ${WORK_BRANCH}

Original issue: #${ISSUE_NUM}: ${ISSUE_TITLE}
${ISSUE_URL}

Original plan: ${PLAN_MD_PATH}
Review with findings: ${REVIEW_MD_PATH}

Your task:
1. Read ${REVIEW_MD_PATH} — especially the "Bugs / gaps" and "Suggested fixes" sections.
2. Read ${CLAUDE_MD_PATH} and ${PLAN_MD_PATH} for context.
3. Apply the fixes. Edit files inside ${REPO_PATH}.
4. Do not introduce new features not covered by the original issue or plan.

Rules:
- Stay inside ${REPO_PATH}.
- Do NOT run `git commit` or `git push` — the wrapper commits.
- If a suggested fix is wrong (would break something), ignore it and say so in your final message.

When done, print a short paragraph describing exactly what you changed.
