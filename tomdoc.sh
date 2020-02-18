#!/usr/bin/env bash

#/ Usage: tomdoc.sh [options] [--] [<shell-script>...]
#/
#/     -h, --help               show help text
#/     --version                show version
#/
#/ Parse TomDoc'd shell scripts and generate pretty documentation from it.
#
# Written by Mathias Lafeldt <mathias.lafeldt@gmail.com>, later project was
# transfered to Tyler Akins <fidian@rumkin.com>.

set -o errexit

# Current version of tomdoc.sh.
readonly TOMDOCSH_VERSION="0.2"

generate=generate_markdown

while test "$#" -ne 0; do
  case "$1" in
  -h | --h | --he | --hel | --help)
    grep '^#/' <"$0" | cut -c4-
    exit 0
    ;;
  --version)
    printf "tomdoc.sh version %s\n" "$TOMDOCSH_VERSION"
    exit 0
    ;;
  --)
    shift
    break
    ;;
  - | [!-]*)
    break
    ;;
  -*)
    printf "error: invalid option '%s'\n" "$1" >&2
    exit 1
    ;;
  esac
done

readonly TYPE_MODULE='module'
readonly TYPE_FUNCTION='function'
readonly TYPE_EXPORT='export'
readonly TYPE_VARIABLE='variable'
readonly TYPE_CONSTANT='constant'
readonly TYPE_UNKNOWN='unknown'

# Regular expression matching at least one whitespace.
readonly SPACE_RE='[[:space:]][[:space:]]*'

# Regular expression matching optional whitespace.
readonly OPTIONAL_SPACE_RE='[[:space:]]*'

# The inverse of the above, must match at least one character
readonly NOT_SPACE_RE='[^[:space:]][^[:space:]]*'

# Regular expression matching shell function or variable name.  Functions may
# use nearly every character.  See [issue #8].  Disallowed characters (hex,
# octal, then a description or a character):
#
#   00 000 null       01 001 SOH        09 011 Tab        0a 012 Newline
#   20 040 Space      22 042 Quote      23 043 #          24 044 $
#   26 046 &          27 047 Apostrophe 28 050 (          29 051 )
#   2d 055 Hyphen     3b 073 ;          3c 074 <          3d 075 =
#   3e 076 >          5b 133 [          5c 134 Backslash  60 140 Backtick
#   7c 174 |          7f 177 Delete
#
# Exceptions allowed as leading character:  \x3d and \x5b
# Exceptions allowed as secondary character: \x23 and \x2d
#
# Must translate to raw characters because Mac OS X's sed does not work with
# escape sequences.  All escapes are handled by printf.
#
# Must use a hyphen first because otherwise it is an invalid range expression.
#
# [issue #8]: https://github.com/tests-always-included/tomdoc.sh/issues/8
readonly FUNC_NAME_RE=$(printf "[^-\\001\\011 \"#$&'();<>\\134\\140|\\177][^\\001\\011 \"$&'();<=>[\\134\\140|\\177]*")

# Regular expression matching variable names.  Similar to FUNC_NAME_RE.
# Variables are far more restrictive.
#
# Leading characters can be A-Z, _, a-z.
# Secondary characters can be 0-9, =, A-Z, _, a-z
readonly VAR_NAME_RE='[A-Z_a-z][0-9A-Z_a-z]*'

# Strip leading whitespace and '#' from TomDoc strings.
#
# Returns nothing.
uncomment() {
  sed -e "s/^$OPTIONAL_SPACE_RE#[[:space:]]\?//"
}

# Generate the documentation for a shell function or variable in markdown format
# and write it to stdout.
#
# $1 - Function or variable name
# $2 - type: function, export, var, ...
# $3 - TomDoc string
#
# Returns nothing.
generate_markdown() {
  local line last did_newline last_was_option
  local title="$1"
  local type="$2"
  local doc="$3"

  if [[ "$type" == "${TYPE_UNKNOWN}" ]]; then
    return
  fi

  # remove line that contains shellcheck
  doc="$(echo "$doc" | grep -v '# shellcheck')"
  if [[ -z "$doc" ]]; then
    return
  fi

  printf '# %s `'%s'`'"\n" "$type" "$title"

  # determine if doc begins with Public or Internal
  currentLineAccess=""
  if [[ $doc =~ ^#\ ((Internal|Public):?)+\ (.*)$ ]]; then
    currentLineAccess="${BASH_REMATCH[2]}"
    doc="# ${BASH_REMATCH[3]}"
  fi
  test -n "${currentLineAccess}" && {
    echo "> ***${currentLineAccess}***"
    echo
  }

  last=""
  did_newline=false
  last_was_option=false

  printf "%s\n" "$doc" | uncomment | sed -e "s/$SPACE_RE$//" | while IFS='' read -r line; do
    if printf "%s" "$line" | grep -q "^$OPTIONAL_SPACE_RE$NOT_SPACE_RE$SPACE_RE-$SPACE_RE"; then
      # This is for arguments
      if ! $did_newline; then
        printf "\n"
      fi

      if printf "%s" "$line" | grep -q "^$NOT_SPACE_RE"; then
        printf "%s" "* $line"
      else
        # Careful - BSD sed always adds a newline
        printf "    * "
        printf "%s" "$line" | sed "s/^$SPACE_RE//" | tr -d "\n"
      fi

      last_was_option=true

      # shellcheck disable=SC2030

      did_newline=false
    else
      case "$line" in
      "")
        # Check for end of paragraph / section
        if ! $did_newline; then
          printf "\n"
        fi

        printf "\n"
        did_newline=true
        last_was_option=false
        ;;

      "  "*)
        # Examples and option continuation
        if $last_was_option; then
          # Careful - BSD sed always adds a newline
          printf "%s" "$line" | sed "s/^ */ /" | tr -d "\n"
          did_newline=false
        else
          printf "  %s\n" "$line"
          did_newline=true
        fi
        ;;

      "* "*)
        # A list should not continue a previous paragraph.
        printf "%s\n" "$line"
        did_newline=true
        ;;
      "\`\`\`"*)
        # A code block should add a new line
        printf "%s\n" "$line"
        did_newline=true
        ;;

      *)
        # Paragraph text (does not start with a space)
        case "$last" in
        "")
          # Start a new paragraph - no space at the beginning
          printf "%s" "$line
"
          ;;

        *)
          # Continue this line - include space at the beginning
          printf " %s" "$line
"
          ;;
        esac

        did_newline=false
        last_was_option=false
        ;;
      esac
    fi

    last="$line"
  done

  # shellcheck disable=SC2031

  if ! $did_newline; then
    printf "\n"
  fi
}

# Read lines from stdin, look for TomDoc'd shell functions and variables, and
# pass them to a generator for formatting.
#
# Returns nothing.
parse_tomdoc() {
  local file="$1"
  local -a functions=()
  local -a constants=()
  local -a variables=()
  local -a exports=()
  local generatedDoc

  doc=
  while read -r line; do
    case "$line" in
    '#' | '# '*)
      doc="$doc$line
"
      ;;
    *)
      test -n "$line" -a -n "$doc" && {

        if [[ $line =~ ^$OPTIONAL_SPACE_RE(function$SPACE_RE)?($FUNC_NAME_RE)$OPTIONAL_SPACE_RE\(\).*$ ]]; then
          type="${TYPE_FUNCTION}"
          name="${BASH_REMATCH[2]}"
        elif [[ $line =~ ^$OPTIONAL_SPACE_RE($FUNC_NAME_RE)$OPTIONAL_SPACE_RE\(\).*$ ]]; then
          type="${TYPE_FUNCTION}"
          name="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^${OPTIONAL_SPACE_RE}export$SPACE_RE($VAR_NAME_RE).*$ ]]; then
          type="${TYPE_EXPORT}"
          name="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^$OPTIONAL_SPACE_RE:$SPACE_RE\${($VAR_NAME_RE):?=.*$ ]]; then
          type="${TYPE_VARIABLE}"
          name="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^${OPTIONAL_SPACE_RE}(declare|typeset)$SPACE_RE(-[a-zA-Z]*$SPACE_RE)?($VAR_NAME_RE)=?.*$ ]]; then
          type="${TYPE_VARIABLE}"
          name="${BASH_REMATCH[3]}"
        elif [[ $line =~ ^${OPTIONAL_SPACE_RE}(readonly)$SPACE_RE(-[a-zA-Z]*$SPACE_RE)?($VAR_NAME_RE)=?.*$ ]]; then
          type="${TYPE_CONSTANT}"
          name="${BASH_REMATCH[3]}"
        else
          type="${TYPE_UNKNOWN}"
          name="$line"
        fi
        generatedDoc=""
        test -n "$name" && {
          generatedDoc="$("$generate" "$name" "$type" "$doc")"
        }
        if [[ -n "${generatedDoc}" ]]; then
          case "$type" in
          "${TYPE_FUNCTION}") functions+=("${generatedDoc}") ;;
          "${TYPE_CONSTANT}") constants+=("${generatedDoc}") ;;
          "${TYPE_VARIABLE}") variables+=("${generatedDoc}") ;;
          "${TYPE_EXPORT}") exports+=("${generatedDoc}") ;;
          esac
        fi
      }
      doc=
      ;;
    esac
  done

  if [[ ${#functions[@]} -eq 0 && ${#variables[@]} -eq 0 && ${#constants[@]} -eq 0 && ${#exports[@]} -eq 0 ]]; then
    # empty file
    return
  fi

  printf "# ${file}\n"

  echoArray() {
    local title="$1"

    if [[ $# -gt 1 ]]; then
      printf "# ${title}\n"
      for elem in "${@:2}"; do
        printf "${elem}\n"
      done
      echo
    fi
  }
  echoArray "Functions" "${functions[@]}"
  echoArray "Variables" "${variables[@]}"
  echoArray "Constants" "${constants[@]}"
  echoArray "Exports" "${exports[@]}"
}
for file in "$@"; do
  cat -- "$file" | parse_tomdoc "$file" | cat -s
done
:
