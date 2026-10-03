#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
EXPERIMENTS_DIR="${EXPERIMENTS_DIR:-$WORKSPACE_DIR/experiments}"
REPORTS_ROOT="${REPORTS_ROOT:-$WORKSPACE_DIR/reports/c1908}"
SET_ANALYSIS_SCRIPT="${SET_ANALYSIS_SCRIPT:-$SCRIPT_DIR/set_analysis.tcl}"
UPSET_BIN="${UPSET_BIN:-UPSET}"

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_DIR/run_experiment.sh
  $SCRIPT_DIR/run_experiment.sh --all

Without options, the script lists the *.tcl files in EXPERIMENTS_DIR and prompts
for one experiment, an inclusive numeric range, or all experiments. Each
experiment is stored in its own directory under REPORTS_ROOT.

Options:
  --all       Run every experiment in sorted filename order.
  -h, --help  Show this help message.

Environment overrides:
  LIB                  default: $WORKSPACE_DIR/pdks/IHP-Open-PDK/ihp-sg13g2
  DESIGN               default: $WORKSPACE_DIR/testcases/iscas85/c1908/c1908.v
  DESIGN_DEF           default: $WORKSPACE_DIR/testcases/iscas85/c1908/c1908.def
  CLK                  default: None
  CLK_PERIOD           default: None
  UPSET_BIN            default: UPSET
  EXPERIMENTS_DIR      default: $EXPERIMENTS_DIR
  REPORTS_ROOT         default: $REPORTS_ROOT
  SET_ANALYSIS_SCRIPT  default: $SET_ANALYSIS_SCRIPT
USAGE
}

list_experiments() {
  if [[ ! -d "$EXPERIMENTS_DIR" ]]; then
    echo "ERROR: experiments directory not found: $EXPERIMENTS_DIR" >&2
    exit 1
  fi

  mapfile -t EXPERIMENT_FILES < <(find "$EXPERIMENTS_DIR" -maxdepth 1 -type f -name '*.tcl' -print | sort)

  if [[ ${#EXPERIMENT_FILES[@]} -eq 0 ]]; then
    echo "ERROR: no .tcl experiment files found under: $EXPERIMENTS_DIR" >&2
    exit 1
  fi
}

prompt_for_experiments() {
  echo "Select an ECO experiment:"
  echo "   0) all experiments"

  local i choice start end
  for i in "${!EXPERIMENT_FILES[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "$(basename "${EXPERIMENT_FILES[$i]}" .tcl)"
  done

  while true; do
    read -r -p "Choice [0-${#EXPERIMENT_FILES[@]}] or range (for example 2-5): " choice
    choice="${choice//[[:space:]]/}"

    if [[ "$choice" == "0" ]]; then
      SELECTED_EXPERIMENT_FILES=("${EXPERIMENT_FILES[@]}")
      return
    fi

    if [[ "$choice" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if ((start >= 1 && end >= start && end <= ${#EXPERIMENT_FILES[@]})); then
        SELECTED_EXPERIMENT_FILES=()
        for ((i = start; i <= end; i++)); do
          SELECTED_EXPERIMENT_FILES+=("${EXPERIMENT_FILES[$((i - 1))]}")
        done
        return
      fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#EXPERIMENT_FILES[@]})); then
      SELECTED_EXPERIMENT_FILES=("${EXPERIMENT_FILES[$((choice - 1))]}")
      return
    fi

    echo "Invalid choice: $choice" >&2
  done
}

validate_experiment_name() {
  local experiment_name="$1"
  if [[ ! "$experiment_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: experiment filenames may contain only letters, digits, dots, underscores, and dashes: $experiment_name" >&2
    exit 2
  fi
}

absolute_path() {
  local path="$1"
  local directory
  directory="$(cd -- "$(dirname -- "$path")" && pwd)"
  printf '%s/%s\n' "$directory" "$(basename -- "$path")"
}

run_one_experiment() {
  local eco_script="$1"
  local experiment_name report_path upset_status
  local -a pipeline_statuses

  experiment_name="$(basename "$eco_script" .tcl)"
  validate_experiment_name "$experiment_name"
  eco_script="$(absolute_path "$eco_script")"
  report_path="$REPORTS_ROOT/$experiment_name"

  export ECO_SCRIPT="$eco_script"
  export REPORT_PATH="$report_path"

  mkdir -p "$REPORT_PATH"
  if [[ ! -w "$REPORT_PATH" ]]; then
    echo "ERROR: report directory is not writable: $REPORT_PATH" >&2
    return 1
  fi

  cat >"$REPORT_PATH/run_env.txt" <<EOF
EXPERIMENT_NAME=$experiment_name
REPORT_PATH=$REPORT_PATH
ECO_SCRIPT=$ECO_SCRIPT
LIB=$LIB
DESIGN=$DESIGN
DESIGN_DEF=$DESIGN_DEF
CLK=$CLK
CLK_PERIOD=$CLK_PERIOD
UPSET_BIN=$UPSET_BIN
EOF

  echo "==> Running experiment: $experiment_name"
  echo "    ECO script: $ECO_SCRIPT"
  echo "    Output:     $REPORT_PATH"

  set +e
  printf 'source %s\nexit\n' "$SET_ANALYSIS_SCRIPT" \
    | "$UPSET_BIN" -no_gui \
    | tee "$REPORT_PATH/upset_stdout.log"
  pipeline_statuses=("${PIPESTATUS[@]}")
  set -e

  upset_status="${pipeline_statuses[1]}"
  if [[ "$upset_status" != "0" ]]; then
    echo "ERROR: UPSET failed for $experiment_name (status=$upset_status)." >&2
    echo "       See: $REPORT_PATH/upset_stdout.log" >&2
    return "$upset_status"
  fi

  if [[ ! -f "$REPORT_PATH/set_gatepins.log" || ! "$REPORT_PATH/set_gatepins.log" -nt "$REPORT_PATH/run_env.txt" ]]; then
    echo "ERROR: the analysis did not produce a fresh set_gatepins.log." >&2
    echo "       See: $REPORT_PATH/upset_stdout.log" >&2
    return 1
  fi

  if [[ ! -f "$REPORT_PATH/set_gatepins.csv" || ! "$REPORT_PATH/set_gatepins.csv" -nt "$REPORT_PATH/run_env.txt" ]]; then
    echo "ERROR: the analysis did not produce a fresh set_gatepins.csv." >&2
    echo "       See: $REPORT_PATH/upset_stdout.log" >&2
    return 1
  fi

  if [[ -f "$REPORT_PATH/eco.log" ]] && grep -q '^ERROR:' "$REPORT_PATH/eco.log"; then
    echo "WARNING: $REPORT_PATH/eco.log contains errors; inspect it before comparing results." >&2
  fi

  echo "==> Completed: $experiment_name"
}

RUN_ALL=0
SELECTED_EXPERIMENT_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      RUN_ALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$SET_ANALYSIS_SCRIPT" ]]; then
  echo "ERROR: SET analysis script not found: $SET_ANALYSIS_SCRIPT" >&2
  exit 1
fi

if [[ "$UPSET_BIN" == */* ]]; then
  if [[ ! -x "$UPSET_BIN" ]]; then
    echo "ERROR: UPSET executable not found or not executable: $UPSET_BIN" >&2
    exit 1
  fi
elif ! command -v "$UPSET_BIN" >/dev/null 2>&1; then
  echo "ERROR: UPSET executable not found in PATH: $UPSET_BIN" >&2
  exit 1
fi

export LIB="${LIB:-$WORKSPACE_DIR/pdks/IHP-Open-PDK/ihp-sg13g2}"
export DESIGN="${DESIGN:-$WORKSPACE_DIR/testcases/iscas85/c1908/c1908.v}"
export DESIGN_DEF="${DESIGN_DEF:-$WORKSPACE_DIR/testcases/iscas85/c1908/c1908.def}"
export CLK="${CLK:-None}"
export CLK_PERIOD="${CLK_PERIOD:-None}"
export UPSET_BIN

list_experiments
if [[ "$RUN_ALL" == "1" ]]; then
  SELECTED_EXPERIMENT_FILES=("${EXPERIMENT_FILES[@]}")
else
  prompt_for_experiments
fi

FAILED_EXPERIMENTS=()
echo "==> Running ${#SELECTED_EXPERIMENT_FILES[@]} experiment(s) from: $EXPERIMENTS_DIR"
for eco_script in "${SELECTED_EXPERIMENT_FILES[@]}"; do
  set +e
  run_one_experiment "$eco_script"
  experiment_status="$?"
  set -e

  if [[ "$experiment_status" != "0" ]]; then
    experiment_name="$(basename "$eco_script" .tcl)"
    FAILED_EXPERIMENTS+=("$experiment_name:$experiment_status")
    echo "WARNING: continuing after failed experiment: $experiment_name" >&2
  fi
done

if [[ ${#FAILED_EXPERIMENTS[@]} -gt 0 ]]; then
  echo "ERROR: ${#FAILED_EXPERIMENTS[@]} experiment(s) failed:" >&2
  printf '  %s\n' "${FAILED_EXPERIMENTS[@]}" >&2
  exit 1
fi

echo "==> All selected experiments completed"
echo "    Outputs: $REPORTS_ROOT"
