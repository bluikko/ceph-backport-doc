#!/usr/bin/env bash 
set -e
#
# ceph-backport-doc.sh - Ceph backporting script for docs PRs
#
# Credits: This script is based on work done by Loic Dachary
#          and the ceph-backport.sh script
#
#
# This script automates the process of staging a docs backport starting from a
# GitHub PR number.
#
# Setup:
#
#     ceph-backport-doc.sh --setup (not implemented as of now)
#
# Usage:
#
#     ceph-backport-doc.sh --help
#     ceph-backport-doc.sh [GitHub PR ID] [release name to backport to]
#
# Example:
#
#     ceph-backport-doc.sh 1920210 tentacle
#

# A GitHub access token is expected either in the environment variable
# github_token or contained in the file $github_token_file

CEPH_UPSTREAM=https://github.com/ceph/ceph.git
github_endpoint=https://github.com/ceph/ceph

github_token_file="$HOME/.github_token"
full_path="$0"
this_script=$(basename "$full_path")
local_branch=""
original_pr=""
original_pr_title=""
original_pr_body=""
original_pr_url=""
merge_commit_sha=""
cherry_pick_sha=""
github_user=""
# the original script has a fancy mechanism to get this from `git remote`
upstream_remote="upstream"

function print_in_hex {
    local str="$1"
    local c

    for (( i=0; i < ${#str}; i++ ))
    do
       c=${str:$i:1}
       if [[ $c == ' ' ]]
       then
          printf "[%s] 0x%X\n" " " \'\ \' >&2
       else
          printf "[%s] 0x%X\n" "$c" \'"$c"\' >&2
       fi
    done
}

function log {
    local level="$1"
    local trailing_newline="yes"
    local in_hex=""
    shift
    local msg="$*"
    prefix="${this_script}: "
    verbose_only=
    case $level in
        bare)
            prefix=
            ;;
        debug)
            prefix="${prefix}DEBUG: "
            verbose_only="yes"
            ;;
        err*)
            prefix="${prefix}ERROR: "
            ;;
        hex)
            in_hex="yes"
            ;;
        info)
            :
            ;;
        overwrite)
            trailing_newline=
            prefix=
            ;;
        verbose)
            verbose_only="yes"
            ;;
        verbose_en)
            verbose_only="yes"
            trailing_newline=
            ;;
        warn|warning)
            prefix="${prefix}WARNING: "
            ;;
    esac
    if [ "$in_hex" ] ; then
        print_in_hex "$msg"
    elif [ "$verbose_only" ] && [ -z "$VERBOSE" ] ; then
        true
    else
        msg="${prefix}${msg}"
        if [ "$trailing_newline" ] ; then
            echo "${msg}" >&2
        else
            echo -en "${msg}" >&2
        fi
    fi
}

function debug {
    log debug "$@"
}

function info {
    log info "$@"
}
function warning {
    log warning "$@"
}
function error {
    log error "$@"
}
function error_fail {
    log error "$@"
    exit 1
}

function assert_fail {
    local message="$1"
    error "(internal error) $message"
    info "This could be reported as a bug!"
    false
}

function test_exists {
    local value="$1"
    local message="$2"
    [ -z "$value" -o "$value" == "null" ] && error_fail "${message} value is empty" || true
}

function test_expected {
    local expected="$1"
    local value="$2"
    local message="$3"
    test_exists "${value}" "${message}"
    [ "$expected" == "$value" ] || error_fail "${message} expected to be '${expected}' but value is '${value}'"
}

function trim_whitespace {
    local var="$*"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

function clip_pr_body {
    local pr_body="$*"
    local clipped=""
    local last_line_was_blank=""
    local line=""
    local pr_json_tempfile=$(mktemp)
    echo "$pr_body" | sed -n '/<!--.*/q;p'
#    echo "$pr_body" | sed 's/<!--.*$//'
#    echo "$pr_body" | sed -n '/<!--.*/q;p' > "$pr_json_tempfile"
#    while IFS= read -r line; do
#        if [ "$(trim_whitespace "$line")" ] ; then
#            last_line_was_blank=""
#            clipped="${clipped}${line}\n"
#        else
#            if [ "$last_line_was_blank" ] ; then
#                true
#            else
#                clipped="${clipped}\n"
#            fi
#        fi
#    done < "$pr_json_tempfile"
#    rm "$pr_json_tempfile"
#    echo "$clipped"
}

function munge_body {
    echo "$*" | tr '\r' '\n' | sed 's/$/\\n/' | tr -d '\n'
}

function print_usage {
    echo "Usage: ${this_script} --help | --setup | [GitHub PR ID] [release name to backport to]"
    echo "Backport a Ceph docs GitHub PR to a stable branch."
    echo ""
    echo "Arguments:"
    echo "    --help    print this help"
    echo "    --setup   configure settings (not implemented)"
    echo ""
    echo "Example: ${this_script} 1920210 tentacle"
    echo ""
    echo "GitHub token is read from env var github_token or from file ${github_token_file}"
}


function set_github_token {
    if [ -z "${github_token}" ] ; then
        if [ -f "${github_token_file}" ] ; then
            github_token=$(cat "${github_token_file}")
            info "GitHub token read from ${github_token_file}"
        else
            error_fail "Environment variable github_token not set and file ${github_token_file} does not exist"
        fi
    else
        info "GitHub token set from environment variable"
    fi
}

function set_github_user_from_github_token {
    local remote_api_output
    local quiet="$1"
    local api_error
    local curl_opts
    setup_ok=""
    [ "$github_token" ] || assert_fail "set_github_user_from_github_token: git_token not set"
    curl_opts="--silent -u :${github_token} https://api.github.com/user"
    [ "$quiet" ] || set -x
    remote_api_output="$(curl $curl_opts)"
    set +x
    github_user=$(echo "${remote_api_output}" | jq -r .login 2>/dev/null | grep -v null || true)
    api_error=$(echo "${remote_api_output}" | jq -r .message 2>/dev/null | grep -v null || true)
    if [ "$api_error" ] ; then
        error "GitHub API said: ->$api_error<-"
        error "If you can't figure out what's wrong by examining the curl command and its output, above,"
        error_fail "please also study https://developer.github.com/v3/users/#get-the-authenticated-user"
    else
        [ "$github_user" ] || assert_fail "set_github_user_from_github_token: failed to set github_user"
        info "my GitHub username is $github_user"
    fi
}

function check_target_branch {
    local remote_api_output
    local api_error

    remote_api_output=$(curl -u ${github_user}:${github_token} --silent "https://api.github.com/repos/ceph/ceph/branches/${target_release}")
    api_error=$(echo "${remote_api_output}" | jq -r .message 2>/dev/null | grep -v null || true)
    if [ "$api_error" ] ; then
        error_fail "GitHub API said: ->$api_error<-"
    fi
    info "${target_release} branch exists upstream"
    # only users with repo admin read permissions can get branch lock status so don't check that
}

function get_and_validate_github_pr {
    local remote_api_output
    local state_is
    local merged_is
    local draft_is
    local base_is
    local commits_is
    local title_is
    local body_is
    local merge_commit_sha_is

    remote_api_output=$(curl -u ${github_user}:${github_token} --silent "https://api.github.com/repos/ceph/ceph/pulls/${original_pr}")

    state_is=$(echo "$remote_api_output" | jq -r '.state')
    merged_is=$(echo "$remote_api_output" | jq -r '.merged')
    draft_is=$(echo "$remote_api_output" | jq -r '.draft')
    base_is=$(echo "$remote_api_output" | jq -r '.base.label')
    commits_is=$(echo "$remote_api_output" | jq -r '.commits')
    title_is=$(echo "$remote_api_output" | jq -r '.title')
    body_is="$(echo "$remote_api_output" | jq -r '.body')"
    html_url_is=$(echo "$remote_api_output" | jq -r '.html_url')
    merge_commit_sha_is=$(printf '%s' "$remote_api_output" | jq -r '.merge_commit_sha')

    test_expected "closed" "${state_is}" "PR state"
    test_expected "true" "${merged_is}" "PR merged"
    test_expected "false" "${draft_is}" "PR draft"
    test_expected "ceph:main" "${base_is}" "PR base"
    test_expected "1" "${commits_is}" "PR commits"
    test_exists "${title_is}" "PR title"
    test_exists "${body_is}" "PR body"
    test_exists "${html_url_is}" "PR URL"
    test_exists "${merge_commit_sha_is}" "PR merge commit SHA"
    original_pr_title="${title_is}"
    original_pr_body="${body_is}"
    original_pr_url="${html_url_is}"
    merge_commit_sha="${merge_commit_sha_is}"
    cherry_pick_sha="${merge_commit_sha}^..${merge_commit_sha}^2"

    if [ "${original_pr_title:0:3}" != "doc" ] ; then
        error_fail "The PR title '${original_pr_title}' does not start with 'doc', is this a docs PR?"
    fi

    info "PR ${original_pr} looks viable: title '${original_pr_title}', merge_commit_sha ${merge_commit_sha}"
}

function branch_and_cherry_pick {
    local_branch="wip-doc-$(date +%Y-%m-%d)-backport-${original_pr}-to-${target_release}"
    info "New local branch will be ${local_branch}"

    git fetch "$CEPH_UPSTREAM" "refs/heads/${target_release}"

    git show-ref --verify --quiet "refs/heads/$local_branch" && error_fail "Local branch ${local_branch} already exists"
    git checkout -b "$local_branch" FETCH_HEAD

    git fetch "$CEPH_UPSTREAM" "$merge_commit_sha"
    git cherry-pick -x "${cherry_pick_sha}" || assert_fail "git cherry-pick ${cherry_pick_sha} failed, check for conflicts and follow instructions from git above"
}

function push_to_github {
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "$local_branch" ] ; then
        git checkout "$local_branch"
    fi
    
    git push -u origin "$local_branch"
}

function open_new_github_pr {
    local backport_pr_title="${target_release}: ${original_pr_title}"
    local desc="$(clip_pr_body "$original_pr_body")"
    local source_repo="${github_user}"

    if [[ "$backport_pr_title" =~ \" ]] ; then
        backport_pr_title="${new_pr_title//\"/\\\"}"
    fi
    if [[ "$desc" =~ \" ]] ; then
        desc="${desc//\"/}"
    fi
    desc="backport of ${original_pr_url}

---

${desc}"

    echo "${desc}"
    info "Creating new GitHub PR '${backport_pr_title}'"

    remote_api_output=$(curl -u ${github_user}:${github_token} --silent --data-binary "{\"title\":\"${backport_pr_title}\",\"head\":\"${source_repo}:${local_branch}\",\"base\":\"${target_release}\",\"body\":\"$(munge_body "${desc}")\"}" "https://api.github.com/repos/ceph/ceph/pulls")
    backport_pr_number=$(echo "$remote_api_output" | jq -r .number)
    if [ -z "$backport_pr_number" ] || [ "$backport_pr_number" = "null" ] ; then
        error "failed to open backport PR"
        echo "${remote_api_output}"
        exit 1
    fi
    local backport_pr_url="${github_endpoint}/pull/$backport_pr_number"
    info "Opened backport PR ${backport_pr_url}"
}

### main

#
# are we in a local git clone?
#

if git status >/dev/null 2>&1 ; then
    debug "In a local git clone. Good."
else
    error_fail "This script must be run from inside a local git clone"
fi

#
# do we have jq available?
#

if type jq >/dev/null 2>&1 ; then
    debug "jq is available. Good."
else
    error_fail "This script uses jq, but it does not seem to be installed"
fi

#
# is jq available?
#

if command -v jq >/dev/null ; then
    debug "jq is available. Good."
else
    error_fail "This script needs \"jq\" in order to work, and it is not available"
fi

if [ -z "${1}" ] ; then
    error_fail "Need PR number as argument"
fi
if [ "${1}" == "--help" ] ; then
    print_usage
    exit 0
else
    original_pr="${1}"
    info "GitHub PR number set to ${original_pr}"
fi

if [ -z "${2}" ] ; then
    error_fail "Need release name as argument"
else
    target_release="${2}"
    info "Target release set to ${target_release}"
fi

set_github_token
set_github_user_from_github_token quiet

check_target_branch
get_and_validate_github_pr
branch_and_cherry_pick
push_to_github
open_new_github_pr
