#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scaffold-clack.sh <target-dir> [basic|spinner] [js|ts] [auto|npm|pnpm|yarn|bun]
  scaffold-clack.sh <target-dir> [basic|spinner] [auto|npm|pnpm|yarn|bun]

Examples:
  scaffold-clack.sh ./my-cli
  scaffold-clack.sh ./my-cli spinner ts
  scaffold-clack.sh ./my-cli basic js pnpm
  scaffold-clack.sh ./my-cli basic pnpm
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

target_dir="${1:-}"
template="${2:-basic}"
arg3="${3:-}"
arg4="${4:-}"

language="js"
package_manager="auto"

# Backward compatibility: allow old signature where arg3 was package manager.
case "$arg3" in
  npm|pnpm|yarn|bun|auto)
    language="js"
    package_manager="$arg3"
    ;;
  "")
    language="js"
    package_manager="auto"
    ;;
  *)
    language="$arg3"
    package_manager="${arg4:-auto}"
    ;;
esac

if [ -z "$target_dir" ]; then
  usage
  exit 1
fi

case "$template" in
  basic|spinner) ;;
  *)
    echo "Invalid template: $template" >&2
    echo "Allowed templates: basic, spinner" >&2
    exit 1
    ;;
esac

case "$language" in
  js|ts) ;;
  *)
    echo "Invalid language: $language" >&2
    echo "Allowed values: js, ts" >&2
    exit 1
    ;;
esac

case "$package_manager" in
  auto|npm|pnpm|yarn|bun) ;;
  *)
    echo "Invalid package manager: $package_manager" >&2
    echo "Allowed values: auto, npm, pnpm, yarn, bun" >&2
    exit 1
    ;;
esac

detect_pm() {
  local dir="$1"
  if [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
    echo "bun"
    return
  fi
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    echo "pnpm"
    return
  fi
  if [ -f "$dir/yarn.lock" ]; then
    echo "yarn"
    return
  fi
  if [ -f "$dir/package-lock.json" ] || [ -f "$dir/npm-shrinkwrap.json" ]; then
    echo "npm"
    return
  fi
  echo ""
}

if [ "$package_manager" = "auto" ]; then
  pm_guess="$(detect_pm "$PWD")"
  package_manager="${pm_guess:-}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$language" = "ts" ]; then
  file_ext="ts"
else
  file_ext="mjs"
fi

template_path="$script_dir/../assets/templates/${template}-cli.${file_ext}"
output_file="$target_dir/cli.${file_ext}"

if [ ! -f "$template_path" ]; then
  echo "Template not found: $template_path" >&2
  exit 1
fi

mkdir -p "$target_dir"

if [ -f "$output_file" ]; then
  echo "Refusing to overwrite existing file: $output_file" >&2
  exit 1
fi

cp "$template_path" "$output_file"

cat <<EOF
Created: $output_file
Template: $template
Language: $language

Next steps:
  1) cd $target_dir
EOF

if [ -n "${package_manager:-}" ]; then
  if [ "$language" = "ts" ]; then
    case "$package_manager" in
      npm)
        cat <<'EOF'
  2) npm i @clack/prompts
  3) npm i -D tsx
  4) npx tsx cli.ts
EOF
        ;;
      pnpm)
        cat <<'EOF'
  2) pnpm add @clack/prompts
  3) pnpm dlx tsx cli.ts
EOF
        ;;
      yarn)
        cat <<'EOF'
  2) yarn add @clack/prompts
  3) yarn dlx tsx cli.ts
EOF
        ;;
      bun)
        cat <<'EOF'
  2) bun add @clack/prompts
  3) bun cli.ts
EOF
        ;;
    esac
  else
    case "$package_manager" in
      npm)
        cat <<'EOF'
  2) npm i @clack/prompts
  3) node cli.mjs
EOF
        ;;
      pnpm)
        cat <<'EOF'
  2) pnpm add @clack/prompts
  3) node cli.mjs
EOF
        ;;
      yarn)
        cat <<'EOF'
  2) yarn add @clack/prompts
  3) node cli.mjs
EOF
        ;;
      bun)
        cat <<'EOF'
  2) bun add @clack/prompts
  3) bun cli.mjs
EOF
        ;;
    esac
  fi
else
  if [ "$language" = "ts" ]; then
    cat <<'EOF'
  2) Install @clack/prompts with your package manager:
     npm i @clack/prompts
     pnpm add @clack/prompts
     yarn add @clack/prompts
     bun add @clack/prompts
  3) Run the CLI:
     npx tsx cli.ts
     pnpm dlx tsx cli.ts
     yarn dlx tsx cli.ts
     bun cli.ts
EOF
  else
    cat <<'EOF'
  2) Install @clack/prompts with your package manager:
     npm i @clack/prompts
     pnpm add @clack/prompts
     yarn add @clack/prompts
     bun add @clack/prompts
  3) Run the CLI:
     node cli.mjs
     bun cli.mjs
EOF
  fi
fi
