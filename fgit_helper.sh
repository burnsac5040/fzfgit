#!/usr/bin/env bash

#######################################
########## SETTING VARIABLES ##########
#######################################
export FZFGIT_TREE="$(git rev-parse --show-toplevel)"
export FZFGIT_DIFF_PAGER="${FZFGIT_DIFF_PAGER:-$(git config core.pager || echo 'cat')}"
export EDITOR="${EDITOR:-vim}"
export FZFGIT_VERSION="v1.2"

[[ -z "${FZF_DEFAULT_OPTS}" ]] && export FZF_DEFAULT_OPTS='--cycle'

if [[ -z "${FZFGIT_KEY}" ]]; then
  FZFGIT_KEY="
    --bind='ctrl-a:toggle-all'
    --bind='ctrl-b:execute(bat --paging=always -f {+})'
    --bind='ctrl-y:execute-silent(echo {+} | pbcopy)'
    --bind='ctrl-e:execute(echo {+} | xargs -o $EDITOR)'
    --bind='ctrl-k:preview-up'
    --bind='ctrl-j:preview-down'
    --bind='alt-j:jump'
    --bind='alt-0:top'
    --bind='ctrl-s:toggle-sort'
    --bind='?:toggle-preview'
"
fi


FZF_DEFAULT_OPTS="
  $FZF_DEFAULT_OPTS
  --ansi
  --cycle
  --exit-0
  $FZFGIT_DEFAULT_OPTS
  $FZFGIT_KEY
"

[[ -z "${COLUMNS}" ]] \
  && COLUMNS=$(stty size < /dev/tty | cut -d' ' -f2)
[[ "${COLUMNS}" -lt 80 ]] \
  && FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS --preview-window=hidden"

#######################################
# determine to set multi selection or not
# Globals:
#   ${FZF_DEFAULT_OPTS}: fzf options
# Arguments:
#   $1: if exists, disable multi, set single
#######################################
set_fzf_multi() {
  local no_multi="$1"
  if [[ -z "${no_multi}" ]]; then
    export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS} --multi"
  else
    export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS} --no-multi"
  fi
}

#######################################
# Helper function to get user confirmation
# Globals:
#   None
# Locals:
#   ${confirm}: user confirmation status
# Arguments:
#   $1: confirmation message to show during confirm
# Outputs:
#   ${confirm}: y or n indicating user response
#######################################
get_confirmation() {
  local confirm
  local message="${1:-Confirm?}"
  while [[ "${confirm}" != 'y' && "${confirm}" != 'n' ]]; do
    read -r -p "${message}[y/n]: " confirm
  done
  echo "${confirm}"
}


#######################################
# let user select a commit interactively
# credit to forgit for the git log format
# Arguments:
#   $1: the helper message to display in the fzf header
#   $2: files to show diff against HEAD
# Outputs:
#   the selected commit 6 char code
#   e.g. b60b330
#######################################
get_commit() {
  local header="${1:-select a commit}"
  local files=("${@:2}")
  if [[ "${#files[@]}" -eq 0 ]]; then
    git  \
      log --color=always --format='%C(auto)%h%d %s %C(black)%C(bold)%cr' \
      | fzf --header="${header}" --no-multi \
          --preview "echo {} \
          | awk '{print \$1}' \
          | xargs -I __ git  \
              show --color=always  __ \
          | ${FZFGIT_DIFF_PAGER}" \
      | awk '{print $1}'
  else
    git \
      log --oneline --color=always --decorate=short \
      | fzf --header="${header}" --no-multi --preview "echo {} \
          | awk '{print \$1}' \
          | xargs -I __ git  \
              diff --color=always __ ${files[*]} \
          | ${FZFGIT_DIFF_PAGER}" \
      | awk '{print $1}'
  fi
}

#######################################
# let user select a branch interactively
# Arguments:
#   $1: the helper message to display in the fzf header
# Outputs:
#   the selected branch name
#   e.g. master
#######################################
get_branch() {
  local header="${1:-select a branch}"
  git branch -a \
    | awk '{
        if ($0 ~ /\*.*\(HEAD.*/) {
          gsub(/\* /, "", $0)
          print "\033[32m" $0 "\033[0m"
        } else if (match($1, "\\*") != 0) {
          print "\033[32m" $2 "\033[0m"
        } else if ($0 ~ /^[ \t]+remotes\/.*/) {
          gsub(/[ \t]+/, "", $0)
          print "\033[31m" $0 "\033[0m"
        } else {
          gsub(/^[ \t]+/, "", $0)
          print $0
        }
      }' \
    | fzf --no-multi --header="${header}" \
        --preview="echo {} \
      | awk '{
          if (\$0 ~ /.*HEAD.*/) {
            print \"HEAD\"
          } else {
            print \$0
          }
        }' \
      | xargs -I __ git \
          log --color=always --color=always --format='%C(auto)%h%d %s %C(black)%C(bold)%cr' __"
}

#######################################
# let user select a git tracked file interactively
# Arguments:
#   $1: the helper message to display in the fzf header
#   $2: print option, values (full|raw)
#   $3: if exist, don't do multi selection, do single
# Outputs:
#   the selected file path
#   e.g.$HOME/.config/nvim/init.vim
#######################################
get_git_file() {
  local mydir
  local header="${1:-select tracked file}"
  local print_opt="${2:-full}"
  mydir="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
  set_fzf_multi "$3"
  git ls-files --full-name --directory "${FZFGIT_TREE}" \
    | fzf --header="${header}" \
        --preview "preview.sh ${FZFGIT_TREE}/{}" \
    | awk -v home="${FZFGIT_TREE}" -v print_opt="${print_opt}" '{
        if (print_opt == "full") {
          print home "/" $0
        } else {
          print $0
        }
      }'
}

#######################################
# let user select a modified file interactively
# Arguments:
#   $1: the helper message to display in the fzf header
#   $2: display mode of modified files.
#     default: true
#     all: display all modified, include staged and unstaged
#     staged: display only staged files
#     unstaged: display only unstaged files
#   $3: output_format
#     default: name
#     name: formatted name of the file
#     raw: raw file name with status
#   $4: if exists, don't do multi selection, do single
# Outputs:
#   the selected file path
#   e.g.$HOME/.config/nvim/init.vim
#######################################

get_modified_file() {
  local header="${1:-select a modified file}"
  local display_mode="${2:-all}"
  local output_format="${3:-name}"
  set_fzf_multi "$4"
  git status --porcelain \
    | awk -v display_mode="${display_mode}" '{
        if ($0 ~ /^[[[:alpha:]]{2}.*$/) {
          print "\033[32m" substr($0, 1, 1) "\033[31m" substr($0, 2) "\033[0m"
        } else if ($0 ~ /^[A-Za-z][ \t].*$/) {
          if (display_mode == "all" || display_mode == "staged") {
            print "\033[32m" $0 "\033[0m"
          }
        } else {
          if (display_mode == "all" || display_mode == "unstaged") {
            print "\033[31m" $0 "\033[0m"
          }
        }
      }' \
    | fzf --header="${header}" --preview "echo {} \
        | awk '{sub(\$1 FS,\"\"); print \$0}' \
        | xargs -I __ git \
            diff HEAD --color=always -- ${FZFGIT_TREE}/__ \
        | ${FZFGIT_DIFF_PAGER}" \
    | awk -v home="${FZFGIT_TREE}" -v format="${output_format}" '{
        if (format == "name") {
          $1=""
          gsub(/^[ \t]/, "", $0)
          gsub(/"/, "", $0)
          print home "/" $0
        } else {
          print $0
        }
      }'
}

#######################################
# let user select a stash interactively
# Arguments:
#   $1: the help message to display in header
#   $2: if exists, don't do multi select, only allow single selection
# Outputs:
#   the selected stash identifier
#   e.g. stash@{0}
#######################################
get_stash() {
  local header="${1:-select a stash}"
  set_fzf_multi "$2"
  git \
    stash list \
    | fzf --header="${header}" --preview "echo {} \
        | awk '{
            gsub(/:/, \"\", \$1)
            print \$1
          }' \
        | xargs -I __ git \
            stash show -p __ --color=always \
        | ${FZFGIT_DIFF_PAGER}" \
    | awk '{
        gsub(/:/, "", $1)
        print $1
      }'
}

#######################################
# Using git grep to find word within
# all tracked files in the bare repo.
# Arguments:
#   $1: the help message to display in header
#   $2: the fzf delimiter to start searching, default is 3
#   $3: if exists, don't do multi select, only allow single selection
# Outputs:
#   the selected file name with it's line number and line, separated by ":"
#   e.g. .bash_profile:1:echo hello
#######################################
grep_words() {
  local header="${1:-select matches to edit}"
  local delimiter="${2:-3}"
  local grep_cmd
  command -v rg >/dev/null && grep_cmd="rg --line-number --no-heading --color=auto --smart-case --ignore='.git' -- ." \
    || grep_cmd="git grep --line-number -- ."
  mydir="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
  set_fzf_multi "$2"
  cd "${FZFGIT_TREE}" || exit
  eval "${grep_cmd}" \
    | fzf --delimiter : --nth "${delimiter}".. --header="${header}" \
        --preview "${mydir}/preview.sh ${FZFGIT_TREE}/{}" \
    | awk -F ":" -v home="${FZFGIT_TREE}" '{
        print home "/" $1 ":" $2
      }'
}

#######################################
# search local file
# Arguments:
#   $1: string, f or d, search file or directory
# Outputs:
#   A user selected file path
#######################################
search_file() {
  local search_type="$1" mydir
  mydir="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
  if [[ "${search_type}" == "f" ]]; then
    find . -maxdepth 1 -type f | sed "s|\./||g" | fzf --multi --preview "${mydir}/preview.sh {}"
  elif [[ "${search_type}" == "d" ]]; then
    if command -v exa &>/dev/null; then
      find . -maxdepth 1 -type d | awk '{if ($0 != "." && $0 != "./.git"){gsub(/^\.\//, "", $0);print $0}}' \
        | fzf --multi --preview "exa -TL 1 --color=always --group-directories-first --icons {}"
    elif command -v tree &>/dev/null; then
      find . -maxdepth 1 -type d | awk '{if ($0 != "." && $0 != "./.git"){gsub(/^\.\//, "", $0);print $0}}' \
        | fzf --multi --preview "tree -L 1 -C --dirsfirst {}"
    else
      find . -maxdepth 1 -type d | awk '{if ($0 != "." && $0 != "./.git"){gsub(/^\.\//, "", $0);print $0}}' | fzf --multi
    fi
  fi
}
