You are reviewing your own most recent implementation against the original GitHub issue. Be strict and specific.

Repository: ${REPO_OWNER}/${REPO_NAME}
Local path: ${REPO_PATH}
Current branch: ${WORK_BRANCH}

Issue #${ISSUE_NUM}: ${ISSUE_TITLE}
${ISSUE_URL}

Body:
${ISSUE_BODY}

Plan file (already implemented): ${PLAN_MD_PATH}

Your task:
1. Read ${CLAUDE_MD_PATH}, ${PLAN_MD_PATH}, and the issue body above.
2. Inspect the change: run `git log -1 --stat` and `git diff HEAD~1..HEAD` inside ${REPO_PATH} to see what was just implemented (there may be multiple review-fix commits already; look at the whole diff vs the base branch: `git diff ${BASE_BRANCH}...HEAD`).
3. Also read the resulting files to check for bugs a diff wouldn't reveal (missing edge cases, broken imports, wrong assumptions).
4. If the repo has runnable tests, try to run them and note the result.

Write a review to: ${REVIEW_MD_PATH}
Structure:
  ## Verdict — one sentence
  ## What was requested vs what was built — bullet mapping
  ## Bugs / gaps — list, empty if none
  ## Style / conventions — list, empty if none
  ## Suggested fixes — actionable list, only if verdict is NEEDS_FIX

After writing the review file, print your final assistant message. The VERY LAST line of that message MUST be one of exactly these two strings, with no trailing characters:

STATUS: OK
STATUS: NEEDS_FIX

Use OK only if the implementation faithfully fulfills the issue and there are no bugs you would want fixed before opening a pull request. Otherwise NEEDS_FIX.
