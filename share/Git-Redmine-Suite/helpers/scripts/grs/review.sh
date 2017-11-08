function review_start {
  TASK=$1
  if [ -z "$TASK" ]; then
    echo "Missing TASK_NUMBER : "
    echo ""
    HELP=1 exec $0
  fi

  git_refresh_local_repos || exit 1
  git_local_repos_is_clean || exit 1

  if git config redmine.review.$TASK.branch > /dev/null; then
    review_continue "$TASK"
  else
    review_create "$TASK"
  fi
}

function review_continue {
  TASK=$1
  BRNAME=$(git config redmine.review.$TASK.branch)
  echo "Continue the review $TASK ..."
  echo ""
  git checkout "$BRNAME"
  git config "redmine.review.current" "$TASK"
}

function review_create {
  TASK=$1
  PR=$(redmine-get-task-pr --task_id=$TASK --cf_names=GIT_PR)
  if [ -z "$PR" ]
      then
      echo "No PR found in the task $TASK"
      echo "Fill the GIT_PR field if you have one."
      echo ""
      exit 1
  fi

  echo -n "Starting the review : "
  if ! redmine-get-task-info --task_id=$TASK --with_status; then
    exit 1
  fi

  if [ -z "$REDMINE_FORCE" ] && [ -z "$REDMINE_CHAIN_FINISH" ] && ! ask_question --question="Do you really want to start the review of this task ?"; then
    exit 1
  fi
  
  task=$TASK \
  status=$REDMINE_REVIEW_IN_PROGRESS \
  assigned_to=$REDMINE_USER_ID \
  cf_id=$REDMINE_GIT_REPOS_ID \
  cf_val=$REDMINE_GIT_REPOS_URL \
  task_update || exit 1
  
  TASK_TITLE=$(redmine-get-task-info --task_id=$TASK)
  SLUG_TITLE=$(slug --this "$TASK_TITLE")
  BRNAME="redmine-review-$SLUG_TITLE"
  
  git checkout -b "$BRNAME" "$PR" || exit 1
  git config "redmine.review.current" "$TASK"
  git config "redmine.review.$TASK.pr" "$PR"
  git config "redmine.review.$TASK.title" "$TASK_TITLE"
  git config "redmine.review.$TASK.branch" "$BRNAME"

  if [ -n "$REDMINE_REBASE" ] ; then
      git rebase origin/devel && (git diff --color origin/devel | less -R)
  else
      git diff --color origin/devel | less -R
  fi
  
  cat <<__EOF__

You can squash / rebase ... 
but please keep the name $BRNAME 
for your branch before further action with git redmine review

To start a review (example):
    git rebase origin/devel
    git diff origin/devel..

If you want to add fixes and send back the branch to the user (if the remote branch is standard):
    git push origin HEAD:redmine-$SLUG_TITLE
or if you have rebase on origin/devel
    git push -f origin HEAD:redmine-$SLUG_TITLE
then
    git redmine review reject

If you want to abort the review
    git redmine review abort

To finish the review:
    git redmine review finish

And don't forget to run your tests before !

__EOF__

}

function review_abort {
  TASK=$(git config redmine.review.current)

  if [ -z "$TASK" ]; then
      echo "You have not start any review !"
      exit 1
  fi

  git_refresh_local_repos || exit 1
  git_local_repos_is_clean || exit 1
  
  TASK_TITLE=$(git config "redmine.review.$TASK.title")
  BRNAME=$(git config "redmine.review.$TASK.branch")
  PR=$(git config "redmine.review.$TASK.pr")

  if [ -z "$REDMINE_FORCE" ] && ! ask_question --question="Do you really want to abort the review of this task : $TASK_TITLE - PR:$PR ?"; then
    exit 1
  fi

  #set -e
  git checkout devel
  git branch -D "$BRNAME"
  #set +e
  review_cleanup_config "$TASK"

  if ! redmine-check-task --task_id "$TASK" --status_ids "$REDMINE_REVIEW_IN_PROGRESS" --assigned_to_id "$REDMINE_USER_ID"; then
    if ! ask_question --question="The ticket has the wrong status, do you want to update it anyway ?"; then
      exit 0
    fi
  fi
  
  task=$TASK \
  status=$REDMINE_REVIEW_TODO \
  assigned_to=$REDMINE_USER_ID \
  task_update || exit 1

}

function review_reject {
  TASK=$(git config redmine.review.current)

  if [ -z "$TASK" ]; then
      echo "You have not start any review !"
      exit 1
  fi

  git_refresh_local_repos || exit 1
  git_local_repos_is_clean || exit 1

  TASK_TITLE=$(git config "redmine.review.$TASK.title")
  BRNAME=$(git config "redmine.review.$TASK.branch")
  PR=$(git config "redmine.review.$TASK.pr")

  if [ -z "$REDMINE_FORCE" ] && ! ask_question --question="Do you really want to reject the review of this task : $TASK_TITLE - PR:$PR ?"; then
    exit 1
  fi

  set -e
  if [ -z "$NO_MESSAGE" ] && [ -z "$MESSAGE" ]; then

  F=$(mktemp /tmp/redmine.XXXXXX)
  cat <<__EOF__ > "$F"

###
### Please indicate to the developer the reasons of your reject.
### 
__EOF__
  $EDITOR "$F"

  MESSAGE=$(cat "$F" | grep -v ^"###")
  RET="
"
  fi
  [ -e "$F" ] && unlink "$F"
  set +e

  echo "Fetching last developer ..."
  declare -a TASK_DEV=($(redmine-get-task-developers --task_id="$TASK" --status_ids="$REDMINE_TASK_IN_PROGRESS" --ids_only))

  ADDITIONAL_MESSAGE=""
  if [ "$MESSAGE" != "$RET" ] && [ -n "$MESSAGE" ]; then
    ADDITIONAL_MESSAGE="

Here the reasons : 

$MESSAGE

"
  fi

  #set -e
  TAG=$(git rev-parse "$BRNAME")
  git checkout "$BRNAME"
  git push -f origin "$BRNAME":"$BRNAME"
  git checkout devel
  git branch -D "$BRNAME"
  review_cleanup_config "$TASK"
  #set +e

  echo ""

  task=$TASK \
  status=$REDMINE_TASK_TODO \
  assigned_to=${TASK_DEV[0]} \
  notes="This task has been rejected.
$ADDITIONAL_MESSAGE

You can take from the review task with :

<pre>
  git redmine task start $TASK
  git reset --hard $TAG
  git push -f
</pre>
" \
  cf_id=$REDMINE_GIT_PR_ID \
  cf_val=" " \
  task_update || exit 1

}

function review_finish {
  TASK=$(git config redmine.review.current)

  if [ -z "$TASK" ]; then
      echo "You have not start any review !"
      exit 1
  fi

  if [ -n "$REDMINE_FORCE" ] && [ -z "$REDMINE_TIME" ]; then
    echo "Please add a spent time thought parameter with the force option !"
    HELP=1 exec $0
  fi
  
  BRNAME=$(git config "redmine.review.$TASK.branch")
  #set -e
  git checkout "$BRNAME"
  git_refresh_local_repos
  git_local_repos_is_clean
  git_local_repos_is_sync_from_devel
  git checkout devel
  git_local_repos_is_sync
  #set +e

  TASK_TITLE=$(git config "redmine.review.$TASK.title")
  TASK_DEV=$(redmine-get-task-developers --task_id="$TASK" --status_ids="$REDMINE_TASK_IN_PROGRESS")
  PR=$(git config "redmine.review.$TASK.pr")
  CHANGELOG=$(get_change_log)

  if [ -z "$REDMINE_FORCE" ] && ! ask_question --question="Do you really want to finish the review of this task : $TASK_TITLE - PR:$PR ?"; then
    exit 1
  fi

  PROJECT=$(redmine-get-task-project-identifier --task_id=$TASK)
  if ! reassigned_this "review" "$PROJECT"; then
    exit 1
  fi

  ADDITIONAL_MESSAGE=""
  REV_FROM=$(git rev-parse origin/devel)

  #set -e
  git merge --no-ff "$BRNAME" -m "Merge $BRNAME"
  echo "    * $TASK_TITLE ($TASK_DEV)" > "$CHANGELOG".new
  touch "$CHANGELOG"
  if head -n1 "$CHANGELOG" | grep -q ^"[0-9]"; then
    echo >> "$CHANGELOG".new
  fi
  cat "$CHANGELOG" >> "$CHANGELOG".new
  mv "$CHANGELOG".new "$CHANGELOG"
  $EDITOR "$CHANGELOG"
  git add "$CHANGELOG"
  git commit -m "reflect changes" "$CHANGELOG" || true
  git push origin devel:devel
  git branch -D "$BRNAME"
  #set +e
  git rev-parse --verify -q origin/"$BRNAME" > /dev/null && git push origin :"$BRNAME"
  review_cleanup_config "$TASK"

  REV_TO=$(git rev-parse origin/devel)
  DIFF_URL=$(get_full_diff_url "$REV_FROM" "$REV_TO")
  if [ -n "$DIFF_URL" ]; then
    ADDITIONAL_MESSAGE="\"View the diff\":$DIFF_URL"
  fi

  task=$TASK \
  status=$REDMINE_RELEASE_TODO \
  assigned_to=$ASSIGNED_TO_ID \
  cf_id=$REDMINE_GIT_PR_ID \
  cf_val=" " \
  notes="
  $ADDITIONAL_MESSAGE
" \
  task_update
  echo ""

  if [ -z "$REDMINE_FORCE" ] || [ -n "$REDMINE_TIME" ]; then
    if [ -z "$REDMINE_TIME" ]; then
      REDMINE_TIME=$(ask_question --question="How many hours did you spend on the review? " --answer_mode="time")
    fi
    echo "Updating time entry ..."
    redmine-create-task-time --task_id=$TASK --hours=$REDMINE_TIME 2> /dev/null || cat <<__EOF__

Impossible to add a time entry :

  * Time tracking is disabled on this project. Please activate it !

__EOF__
  fi

}

function review_cleanup_config {
  TASK=$1
  git config --remove-section "redmine.review.$TASK"
  git config --unset redmine.review.current
  [ -z "$(git config --get-regexp ^'redmine\.review\.')" ] && git config --remove-section "redmine.review"
  return 0
}
