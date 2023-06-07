#!/bin/bash
# set -eux

max_lookback_time=2*3600

workflow_name=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "https://circleci.com/api/v2/workflow/${CIRCLE_WORKFLOW_ID}" | jq -r '.name')
# workflow_name="build-deploy"

echo "Workflow name: ${workflow_name}"

reqs=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "https://circleci.com/api/v2/project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${CIRCLE_BRANCH}")
pipeline_ids=$(echo "$reqs" | jq -r '.items[].id')
next_page_token=$(echo "$reqs" | jq -r 'if .items | any (.created_at | sub("(?<time>.*)\\..*Z"; "\(.time)Z") | fromdateiso8601 < (now - '"${max_lookback_time}"') ) then null else .next_page_token end')

while [ "$next_page_token" != "null" ]; do
    reqs=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "https://circleci.com/api/v2/project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?page-token=${next_page_token}")
    pipeline_ids=$(printf "%s\n%s" "${pipeline_ids}" "$(echo "$reqs" | jq -r '.items[].id')")
    next_page_token=$(echo "$reqs" | jq -r 'if .items | any (.created_at | sub("(?<time>.*)\\..*Z"; "\(.time)Z") | fromdateiso8601 < (now - '"${max_lookback_time}"') ) then null else .next_page_token end')
done

echo "Pipeline ids: ${pipeline_ids}"

workflow_ids=$(echo "${pipeline_ids}" | while read pip_id; do
    wf_reqs=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "https://circleci.com/api/v2/pipeline/${pip_id}/workflow")
    echo "$wf_reqs" | jq -r ".items[] | select ( .name == \"${workflow_name}\" and .status == \"running\" and .id != \"${CIRCLE_WORKFLOW_ID}\").id "
    wf_next_page_token=$(echo "$wf_reqs" | jq -r '.next_page_token')

    while [ "$wf_next_page_token" != "null" ]; do
        wf_reqs=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "https://circleci.com/api/v2/pipeline/${pip_id}/workflow?page-token=${next_page_token}")
        echo "$wf_reqs" | jq -r ".items[] | select ( .name == \"${workflow_name}\" and .status == \"running\" and .id != \"${CIRCLE_WORKFLOW_ID}\").id "
        wf_next_page_token=$(echo "$wf_reqs" | jq -r '.next_page_token')
    done

done)
echo "Workflow ids: ${workflow_ids}"

echo "${workflow_ids}" | while read wf_id; do
    if [ -n "${wf_id}" ]; then
        echo "Cancel workflow ${wf_id}"
        curl -fsS -X POST -H "Circle-Token: ${CIRCLECI_TOKEN}" "https://circleci.com/api/v2/workflow/${wf_id}/cancel"
    fi
done
