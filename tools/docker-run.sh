#!/usr/bin/env bash
#
# Run jekyll serve inside a Docker container
# Uses a named volume to cache bundled gems across runs.

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VOLUME_NAME="jekyll_bundle_evanstoddard"

prod=false

help() {
  echo "Usage:"
  echo
  echo "   bash tools/docker-run.sh [options]"
  echo
  echo "Options:"
  echo "     -p, --production     Run Jekyll in 'production' mode."
  echo "     -h, --help           Print this help information."
}

while (($#)); do
  opt="$1"
  case $opt in
  -p | --production)
    prod=true
    shift
    ;;
  -h | --help)
    help
    exit 0
    ;;
  *)
    echo -e "> Unknown option: '$opt'\n"
    help
    exit 1
    ;;
  esac
done

env_flag=""
if $prod; then
  env_flag="-e JEKYLL_ENV=production"
fi

echo "> Starting Jekyll in Docker (site served at http://127.0.0.1:4000)"
echo "> First run will install gems (cached for subsequent runs)"
echo "> Press Ctrl+C to stop"
echo

exec docker run --rm -it \
  -p 4000:4000 \
  -p 35729:35729 \
  -v "${SITE_DIR}:/srv/jekyll" \
  -v "${VOLUME_NAME}:/usr/local/bundle" \
  -w /srv/jekyll \
  $env_flag \
  ruby:3.3 \
  bash -c "bundle install && bundle exec jekyll serve --livereload -H 0.0.0.0"
