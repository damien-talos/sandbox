#!/bin/bash
set -euo pipefail
shopt -s lastpipe

# The purpose of this shell script is to act as a smarter version of
# Circle CI's built-in "Auto-cancel redundant builds" setting.
# The built in version will cancel *any* builds for that branch, even
# if they are a different workflow, so we can't have both a regular
# build and a preview build running at the same time.
# Disabling that feature, and running this shell script at the beginning
# of every build, allows us to still only run one build at a time, but
# that is now 1 build *per branch* *per workflow* (so we can have regular
# and preview builds simulataneously).

API_URL="https://circleci.com/api/v2"
function api-get() {
    curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "${API_URL}/$1"
}
function api-post() {
    curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" -x POST "${API_URL}/$1"
}

# Circle CI doesn't give any easy way to query for all running builds.
# Our only solution is to query for *all* the pipelines for this branch,
# and go back far enough in time that we know there couldn't be any older
# builds possibly running.
# This value is defined in milliseconds.
max_lookback_time=$((2 * 3600))

# Need to query the API to find out the current workflow name ('build-deploy', 'build-deploy-preview', etc.)
workflow_name=$(api-get "workflow/${CIRCLE_WORKFLOW_ID}" | jq -r '.name')
workflow_created_at=$(api-get "workflow/${CIRCLE_WORKFLOW_ID}" | jq -r '.created_at | sub("(?<time>.*)\\..*Z"; "\(.time)Z") | fromdateiso8601')

echo "Current workflow name: ${workflow_name}"

# Step 1:
# First we need to load all the pipelines for the current branch, going as far back as ${max_lookback_time}.
# We use `jq` to parse the ids out of the api response, and to parse out the next page token

# Breakdown of this query:
# - if any items (pipelines) were created more than ${max_lookback_time} ago, then return null, else return the next page token
# - Breakdown of the if condition
#   - `.created_at` is the date/time the pipeline was created, in ISO8601 format, but it includes microseconds
#      jq's `fromdateiso8601` doesn't support microseconds (see https://github.com/jqlang/jq/issues/1409), so we strip them with the `sub` regex
#   - After stripping microseconds, we parse the date with `fromdateiso8601` and then it to the oldest time we care about
jq_pipeline_next_page_token_query='if .items | any (.created_at | sub("(?<time>.*)\\..*Z"; "\(.time)Z") | fromdateiso8601 < (now - '"${max_lookback_time}"') ) then null else .next_page_token end'

pipeline_ids=$(
    reqs=$(api-get "project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${CIRCLE_BRANCH}")
    echo "$reqs" | jq -r '.items[].id'
    next_page_token=$(echo "$reqs" | jq -r "${jq_pipeline_next_page_token_query}")

    while [ "$next_page_token" != "null" ]; do
        reqs=$(api-get "project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?page-token=${next_page_token}")
        echo "$reqs" | jq -r '.items[].id'
        next_page_token=$(echo "$reqs" | jq -r "${jq_pipeline_next_page_token_query}")
    done
)

echo "Pipeline ids:"
echo "${pipeline_ids}"

# Step 2:
# We load the workflows for each of the pipelines we've listed in Step 1.
# We want to find any workflows that are currently running, we don't care about any others.

# Breakdown of this query:
# - Select the id of all workflows with the same name as the current workflow, are running, were created before the current workflow, and aren't the current workflow.
jq_workflow_running_workflow_query=".items[] | select ( .name == \"${workflow_name}\" and .status == \"running\" and .id != \"${CIRCLE_WORKFLOW_ID}\" and .created_at | fromdateiso8601 < \"${workflow_created_at}\") | .id"

workflow_ids=$(echo "${pipeline_ids}" | while read -r pip_id; do
    wf_reqs=$(api-get "pipeline/${pip_id}/workflow")
    echo "$wf_reqs" | jq -r "${jq_workflow_running_workflow_query}"
    next_page_token=$(echo "$wf_reqs" | jq -r '.next_page_token')

    while [ "$next_page_token" != "null" ]; do
        wf_reqs=$(api-get "pipeline/${pip_id}/workflow?page-token=${next_page_token}")
        echo "$wf_reqs" | jq -r "${jq_workflow_running_workflow_query}"
        next_page_token=$(echo "$wf_reqs" | jq -r '.next_page_token')
    done

done)

echo "Workflow ids:"
echo "${workflow_ids}"

# Step 3:
# Cancel all the running workflows that we found

echo "${workflow_ids}" | while read -r wf_id; do
    if [ -n "${wf_id}" ]; then
        echo "Cancel workflow ${wf_id}"
        api-post "workflow/${wf_id}/cancel"
    fi
done
