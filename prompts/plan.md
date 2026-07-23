You are planning the implementation of a GitHub issue. Do NOT write code yet.

Repository: ${REPO_OWNER}/${REPO_NAME}
Local path: ${REPO_PATH}
Current branch: ${WORK_BRANCH}
Base branch: ${BASE_BRANCH}

Issue #${ISSUE_NUM}: ${ISSUE_TITLE}
${ISSUE_URL}

Body:
${ISSUE_BODY}

Your task:
1. Read ${REPO_PATH}/CLAUDE.md for project context.
2. Read whatever files in ${REPO_PATH} are relevant to this issue.
3. Write a concise plan to: ${PLAN_MD_PATH}

Structure of the plan file:
  ## Goal — one sentence
  ## Files to touch — bullet list with reason each
  ## Approach — 3-8 short steps
  ## Tests / verification — how we'll know it works
  ## Out of scope — anything the issue could imply but that we won't do

Be honest about ambiguity. If the issue is under-specified, note the assumption you're making.

After writing ${PLAN_MD_PATH}, print a one-line summary and stop. Do NOT create any other files. Do NOT modify existing files.
