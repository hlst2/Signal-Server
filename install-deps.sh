#!/usr/bin/env bash
#
# install-deps.sh — provision a fresh Debian host to build AND run Signal-Server locally.
#
# Build dependencies (installed system-wide):
#   - System build prerequisites (git, curl, ca-certificates, build-essential, gnupg, lsb-release)
#   - Eclipse Temurin JDK 25 (required by .java-version)
#   - Docker Engine + Compose plugin (required by testcontainers-based tests)
#   - FoundationDB client library 7.3.62 (libfdb_c.so; required at build/test time)
#
# Runtime setup (in the repo):
#   - Initializes the private 'spam-filter' submodule when possible, else skips it
#     and configures the build to use the -Pexclude-spam-filter profile.
#   - Pre-pulls the Docker images that testcontainers needs (DynamoDB Local, Redis,
#     redis-cluster, LocalStack, FoundationDB) so the first server start is fast.
#   - Drops a 'run-local.sh' wrapper at the repo root that starts the feature-limited
#     test server (LocalWhisperServerService) with all dependencies auto-provisioned
#     in-process by testcontainers.
#
# Maven is NOT installed system-wide — the repo ships ./mvnw which downloads its own.
#
# Tested against: Debian 12 (bookworm) and Debian 13 (trixie), amd64.
#
# Usage:
#   sudo ./install-deps.sh                # full install + runtime setup
#   sudo ./install-deps.sh --skip-pull    # skip the image pre-pull (~1 GB of pulls)
#
# Re-runnable: each step is idempotent and skips work already done.

set -euo pipefail

SKIP_PULL=0
SKIP_WARM=0
for arg in "$@"; do
  case "$arg" in
    --skip-pull) SKIP_PULL=1 ;;
    --skip-warm) SKIP_WARM=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Resolve the repo root (the directory this script lives in). All runtime-config
# files we generate are written here, so the user can re-run the script from any cwd.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Ryuk is the testcontainers reaper container. testcontainers-bom 2.0.4 needs it,
# and it doesn't appear in any pom.xml — so we pre-pull a recent stable tag. If
# testcontainers wants a different tag at runtime it'll log and pull on first
# use; setting TESTCONTAINERS_RYUK_DISABLED=true (done in run-local.sh) is the
# fallback for fully-offline runs.
RYUK_IMAGE="testcontainers/ryuk:0.11.0"

# Run a command as the invoking (non-root) user. Used for any step that touches
# files under the user's HOME (e.g., Maven's ~/.m2, git submodules in the repo).
# If the script wasn't invoked via sudo, runs as the current user (root).
as_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "${SUDO_USER}" -H "$@"
  else
    "$@"
  fi
}

# ---------- pinned versions (keep in sync with pom.xml / .java-version) -----------
FDB_VERSION="7.3.62"
FDB_CLIENT_SHA256="bfed237b787fae3cde1222676e6bfbb0d218fc27bf9e903397a7a7aa96fb2d33"
JDK_MAJOR="25"        # matches .java-version: temurin-25

# ---------- helpers --------------------------------------------------------------
log()  { printf '\n\033[1;34m[install-deps]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[install-deps]\033[0m %s\n' "$*" >&2; }
err()  { printf '\n\033[1;31m[install-deps]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (try: sudo $0)."
  fi
}

check_debian() {
  [[ -r /etc/os-release ]] || err "/etc/os-release not found — this script targets Debian."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian) : ;;
    ubuntu) warn "Detected Ubuntu — script is written for Debian but should mostly work." ;;
    *)      err "Unsupported distro '${ID:-unknown}'. This script targets Debian." ;;
  esac
  DISTRO_ID="${ID}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$DISTRO_CODENAME" ]] || err "Could not detect distro codename from /etc/os-release."
  log "Detected ${ID} ${VERSION_ID:-?} (${DISTRO_CODENAME}), arch $(dpkg --print-architecture)."
}

check_arch() {
  local arch
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    err "Unsupported architecture '$arch'. FoundationDB client pinned in pom.xml is x86_64-only."
  fi
}

# ---------- 1. base packages -----------------------------------------------------
install_base_packages() {
  log "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    build-essential \
    unzip \
    procps
}

# ---------- 2. JDK ---------------------------------------------------------------
install_temurin_jdk() {
  if command -v java >/dev/null 2>&1; then
    local current
    current="$(java -version 2>&1 | head -n1 | sed -E 's/.*"([0-9]+).*/\1/')"
    if [[ "$current" == "$JDK_MAJOR" ]]; then
      log "Temurin JDK $JDK_MAJOR already present — skipping."
      return
    fi
  fi

  log "Installing Eclipse Temurin JDK $JDK_MAJOR via Adoptium APT repo..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/adoptium.gpg ]]; then
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
    chmod a+r /etc/apt/keyrings/adoptium.gpg
  fi
  # Adoptium publishes per-Debian-codename repos.
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${DISTRO_CODENAME} main" \
    > /etc/apt/sources.list.d/adoptium.list

  apt-get update
  apt-get install -y --no-install-recommends "temurin-${JDK_MAJOR}-jdk"

  java -version
}

# ---------- 3. Docker ------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Engine + Compose plugin already installed — skipping."
    return
  fi

  log "Installing Docker Engine (from Docker's official APT repo)..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker || warn "Could not enable docker via systemctl (container env?). Start it manually if needed."
}

# Add the invoking user (or $SUDO_USER) to the docker group so they can run tests
# without sudo. Takes effect after the next login.
add_user_to_docker_group() {
  local target_user="${SUDO_USER:-}"
  if [[ -z "$target_user" || "$target_user" == "root" ]]; then
    return
  fi
  if id -nG "$target_user" | tr ' ' '\n' | grep -qx docker; then
    log "User '$target_user' already in docker group."
    return
  fi
  log "Adding '$target_user' to docker group (re-login required)."
  usermod -aG docker "$target_user"
}

# ---------- 4. FoundationDB client ----------------------------------------------
install_foundationdb_client() {
  # The pom.xml pins libfdb_c.so version + SHA256. We install the matching .deb
  # so libfdb_c.so lives at /usr/lib/libfdb_c.so (where the JNI bindings look).
  local deb_url="https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_amd64.deb"
  local tmp_deb="/tmp/foundationdb-clients_${FDB_VERSION}-1_amd64.deb"

  if dpkg -s foundationdb-clients >/dev/null 2>&1; then
    local installed
    installed="$(dpkg-query -W -f='${Version}' foundationdb-clients 2>/dev/null || true)"
    if [[ "$installed" == "${FDB_VERSION}-1" ]]; then
      log "foundationdb-clients ${FDB_VERSION} already installed — skipping."
      return
    else
      warn "Found foundationdb-clients $installed, replacing with ${FDB_VERSION}."
    fi
  fi

  log "Downloading FoundationDB client ${FDB_VERSION}..."
  curl -fSL --retry 3 -o "$tmp_deb" "$deb_url"
  apt-get install -y --no-install-recommends "$tmp_deb"
  rm -f "$tmp_deb"

  # Sanity-check the SHA256 of the resulting libfdb_c.so against the pom.xml pin.
  # (The .deb may also drop a versioned name; check both.)
  local lib
  for lib in /usr/lib/libfdb_c.so /usr/lib/libfdb_c.x86_64.so /usr/lib/x86_64-linux-gnu/libfdb_c.so; do
    if [[ -f "$lib" ]]; then
      local got
      got="$(sha256sum "$lib" | awk '{print $1}')"
      if [[ "$got" == "$FDB_CLIENT_SHA256" ]]; then
        log "Verified $lib SHA256 against pom.xml pin."
        ldconfig
        return
      fi
    fi
  done
  warn "Could not verify libfdb_c.so SHA256 matches the pom.xml pin (${FDB_CLIENT_SHA256})."
  warn "The build may still work if FoundationDB ships a matching binary under a name we didn't check."
  ldconfig
}

# ---------- 5. spam-filter submodule --------------------------------------------
# The 'spam-filter' submodule has a REDACTED URL in .gitmodules (private repo).
# If the invoking user has configured a real URL via `git config submodule.spam-filter.url`,
# try to initialize it; otherwise leave it alone and the build will use -Pexclude-spam-filter.
setup_spam_filter_submodule() {
  if [[ ! -f "${REPO_ROOT}/.gitmodules" ]]; then
    return
  fi

  local configured_url
  configured_url="$(as_user git -C "${REPO_ROOT}" config --get submodule.spam-filter.url 2>/dev/null || true)"

  if [[ -n "$configured_url" && "$configured_url" != "REDACTED" ]]; then
    log "Initializing spam-filter submodule from configured URL..."
    if as_user git -C "${REPO_ROOT}" submodule update --init --recursive spam-filter; then
      USE_EXCLUDE_SPAM_FILTER=0
      return
    fi
    warn "spam-filter submodule init failed; build will use -Pexclude-spam-filter."
  else
    log "spam-filter submodule URL not configured (private repo) — build will use -Pexclude-spam-filter."
  fi
  USE_EXCLUDE_SPAM_FILTER=1
}

# ---------- 6. warm Maven local repository ---------------------------------------
# After this step, ~/.m2/repository contains every JAR (compile + test + plugins)
# needed to build and run the test server, so subsequent ./mvnw invocations can
# run with -o (offline) and never contact a remote repository.
#
# Run as the invoking user so the cache lands in their HOME, not root's.
warm_maven_cache() {
  if [[ "$SKIP_WARM" == "1" ]]; then
    log "Skipping Maven cache warm (--skip-warm) — offline runs WILL fail until you populate ~/.m2."
    return
  fi

  # Activate the same profile set that run-local.sh will use, so plugins bound
  # only inside those profiles (e.g. exec-maven-plugin under test-server) get
  # resolved into ~/.m2 too.
  local profiles="-Ptest-server"
  [[ "${USE_EXCLUDE_SPAM_FILTER:-1}" == "1" ]] && profiles="-Ptest-server,exclude-spam-filter"

  log "Warming Maven local repository (~/.m2/repository); this can take several minutes..."

  # dependency:go-offline fetches direct + transitive deps. It tends to miss some
  # plugin-execution-time deps, so we follow up with a real test-compile which
  # exercises every plugin we actually use at build time.
  if ! as_user bash -c "cd '$REPO_ROOT' && ./mvnw -B -q $profiles dependency:go-offline -DskipTests=true"; then
    warn "dependency:go-offline reported errors (often non-fatal); continuing with test-compile."
  fi

  # test-compile pulls in the test classpath including testcontainers libs that
  # run-local.sh will need. We DO NOT run unit tests here — that would spin up
  # all the testcontainers images and take ~20 min.
  if ! as_user bash -c "cd '$REPO_ROOT' && ./mvnw -B $profiles clean test-compile -DskipTests=true"; then
    err "Maven test-compile failed — the build is broken; re-run install-deps.sh after fixing."
  fi

  log "Maven cache warmed. ~/.m2/repository size: $(as_user du -sh "$(as_user bash -c 'echo $HOME')/.m2/repository" 2>/dev/null | awk '{print $1}' || echo "?")"
}

# ---------- 7. pre-pull testcontainer images -------------------------------------
# The local test server provisions DynamoDB / Redis / LocalStack / FoundationDB
# in Docker containers on demand via testcontainers. Pre-pulling them means the
# server can start with no network access — testcontainers uses image-IfPresent
# semantics and only pulls when the image is missing.
pre_pull_test_images() {
  if [[ "$SKIP_PULL" == "1" ]]; then
    log "Skipping test-image pre-pull (--skip-pull) — offline runs WILL fail until these images are cached locally."
    return
  fi

  # Image pins lifted from pom.xml properties + TestcontainersFoundationDbDatabaseLifecycleManager.
  # RYUK_IMAGE is set near the top of the script and matched in run-local.sh.
  local images=(
    "amazon/dynamodb-local:3.3.0"
    "redis:7.4-alpine"
    "docker.io/bitnamilegacy/redis-cluster:7.4.3"
    "localstack/localstack:4.13"
    "foundationdb/foundationdb:${FDB_VERSION}"
    "${RYUK_IMAGE}"
  )

  log "Pre-pulling testcontainer images (skip with --skip-pull)..."
  local img
  for img in "${images[@]}"; do
    printf '  pulling %s\n' "$img"
    if ! docker pull --quiet "$img"; then
      warn "Failed to pull $img — if this is ryuk, run-local.sh sets TESTCONTAINERS_RYUK_DISABLED=true as fallback."
    fi
  done
}

# ---------- 8. write run-local.sh wrapper ----------------------------------------
write_run_wrapper() {
  local wrapper="${REPO_ROOT}/run-local.sh"
  local profile_flag=""
  [[ "${USE_EXCLUDE_SPAM_FILTER:-1}" == "1" ]] && profile_flag=",exclude-spam-filter"

  log "Writing $wrapper ..."
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
#
# run-local.sh — start the feature-limited Signal-Server test instance.
#
# Generated by install-deps.sh. Edit freely; re-running install-deps.sh will
# overwrite this file.
#
# This uses LocalWhisperServerService, which loads service/src/test/resources/
# config/test.yml + test-secrets-bundle.yml. DynamoDB and Redis are spun up
# automatically inside Docker via testcontainers; external services (CDS, SVR,
# registration, payments, push) are stubbed.
#
# Offline by default: assumes ~/.m2/repository was warmed by install-deps.sh
# and all required Docker images are cached locally. Pass --online to re-allow
# Maven network access (e.g. after upgrading a dependency).
#
# Override the config path with SIGNAL_SERVER_CONFIG=/path/to/your.yml

set -euo pipefail
cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")"

OFFLINE_FLAG="-o"
EXTRA_ARGS=()
for a in "\$@"; do
  case "\$a" in
    --online) OFFLINE_FLAG="" ;;
    *)        EXTRA_ARGS+=("\$a") ;;
  esac
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not reachable — start it with: sudo systemctl start docker" >&2
  echo "If you just ran install-deps.sh, you may also need to re-login so your" >&2
  echo "user picks up the docker group membership (or run: newgrp docker)." >&2
  exit 1
fi

# Prevent the AWS / Google SDKs from probing 169.254.169.254 (EC2 IMDS) and
# metadata.google.internal looking for credentials. Without these, startup can
# stall for ~30s per SDK on hosts with no network, before falling through to
# the static credentials configured in test.yml.
export AWS_EC2_METADATA_DISABLED="\${AWS_EC2_METADATA_DISABLED:-true}"
export NO_GCE_CHECK="\${NO_GCE_CHECK:-true}"

# Pin the testcontainers reaper image to one install-deps.sh pre-pulled. If
# that pull failed (or the testcontainers library wants a different tag), the
# RYUK_DISABLED fallback below makes startup proceed without a reaper — at the
# cost of leaving orphaned containers around if this script is killed with -9.
export TESTCONTAINERS_RYUK_CONTAINER_IMAGE="\${TESTCONTAINERS_RYUK_CONTAINER_IMAGE:-${RYUK_IMAGE}}"
if ! docker image inspect "\$TESTCONTAINERS_RYUK_CONTAINER_IMAGE" >/dev/null 2>&1; then
  echo "[run-local.sh] ryuk image \$TESTCONTAINERS_RYUK_CONTAINER_IMAGE not cached; disabling ryuk." >&2
  export TESTCONTAINERS_RYUK_DISABLED=true
fi

# testcontainers' "startup check" pings a public registry by default; disable.
export TESTCONTAINERS_CHECKS_DISABLE="\${TESTCONTAINERS_CHECKS_DISABLE:-true}"

exec ./mvnw \$OFFLINE_FLAG -Ptest-server${profile_flag} integration-test -DskipTests=true "\${EXTRA_ARGS[@]}"
EOF
  chmod +x "$wrapper"

  # Make sure the new file is owned by the invoking user, not root.
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown "${SUDO_USER}:" "$wrapper" || true
  fi
}

# ---------- 9. summary -----------------------------------------------------------
print_summary() {
  local profile_hint=""
  [[ "${USE_EXCLUDE_SPAM_FILTER:-1}" == "1" ]] && profile_hint=" -Pexclude-spam-filter"

  cat <<EOF

============================================================
  Signal-Server installed and ready for offline runtime.
============================================================

Versions:
  JDK:            $(java -version 2>&1 | head -n1)
  Docker:         $(docker --version 2>/dev/null || echo 'not detected')
  Compose plugin: $(docker compose version 2>/dev/null | head -n1 || echo 'not detected')
  FoundationDB:   $(dpkg-query -W -f='\${Package} \${Version}\n' foundationdb-clients 2>/dev/null || echo 'not detected')

Spam-filter: $( [[ "${USE_EXCLUDE_SPAM_FILTER:-1}" == "1" ]] && echo "excluded (private submodule unavailable)" || echo "initialized from configured submodule URL" )
Maven cache: $( [[ "$SKIP_WARM" == "1" ]] && echo "NOT warmed (--skip-warm) — offline runs will fail" || echo "warmed (offline-ready)" )
Images:      $( [[ "$SKIP_PULL" == "1" ]] && echo "NOT pre-pulled (--skip-pull) — offline runs will fail" || echo "pre-pulled (offline-ready)" )

Next steps:
  1. Log out and back in (or run 'newgrp docker') so the docker group takes effect.
  2. Start the feature-limited local server (works fully offline):
       ./run-local.sh
     It listens on the ports configured in service/src/test/resources/config/test.yml
     (HTTP 8080 by default; gRPC 50051). Stub services mean SMS verification accepts any
     code and captcha 'noop.noop.registration.noop' always passes — see TESTING.md.
  3. To re-allow Maven network access after upgrading deps:
       ./run-local.sh --online
  4. To run unit tests:
       ./mvnw${profile_hint} test

Offline contract: once this script has finished successfully, ./run-local.sh
will start the server with NO network access required. Specifically:
  * Maven runs in offline mode (-o); ~/.m2/repository contains all needed JARs.
  * All Docker images testcontainers needs are cached locally.
  * AWS_EC2_METADATA_DISABLED and NO_GCE_CHECK prevent SDKs from stalling on
    169.254.169.254 (EC2 IMDS) or metadata.google.internal lookups.
  * Calls to *.example.com hostnames in test.yml are made lazily by gRPC stubs;
    they log DNS errors when actually invoked but do not block server startup.

Limitations of this 'runtime' setup:
  * It runs LocalWhisperServerService, not the production WhisperServerService entrypoint.
    Every "external" Signal service (CDS, SVR2, SVRB, storage, registration, key transparency,
    TUS, push) is stubbed — they won't actually deliver SMS, push, etc.
  * It uses ephemeral DynamoDB/Redis (data is wiped on every server restart).
  * Payment providers (Stripe/Braintree/Apple/Google) are stubbed; donation flows won't
    complete real transactions.
  * Running the production entrypoint additionally requires a live FoundationDB cluster
    (apt install foundationdb-server) plus real credentials and external services — that
    setup is not in scope for this script.
EOF
}

main() {
  require_root
  check_debian
  check_arch
  install_base_packages
  install_temurin_jdk
  install_docker
  add_user_to_docker_group
  install_foundationdb_client
  setup_spam_filter_submodule
  warm_maven_cache
  pre_pull_test_images
  write_run_wrapper
  print_summary
}

main "$@"
