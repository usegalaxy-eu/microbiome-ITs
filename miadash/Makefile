# miaDash is not vendored. The image build clones the app itself inside the
# Dockerfile, and `deps` clones a separate copy outside the repository for the
# tests to read. Nothing app-related is ever written into this build tree.
UPSTREAM_URL=https://github.com/paulzierep/miaDash
# The fork's `galaxy-it-adaptations` branch carries the Send-to-Galaxy buttons
# and the staged raw-table import. Plain upstream would be the `devel` branch
# (the repository default).
UPSTREAM_REF=galaxy-it-adaptations

# Where `deps` keeps the checkout. Kept outside the repository on purpose: a
# checkout inside the build tree is a file the Dockerfile could pick up, and it is
# one `rm -rf` away from being committed by accident.
DEPS_ROOT?=/tmp/microbiome-ITs
UPSTREAM_DIR=$(DEPS_ROOT)/miadash/miaDash
# R/galaxy_ie.R only exists on the Galaxy branch, so it doubles as the proof
# that `make deps` got the adapted checkout rather than plain upstream.
UPSTREAM_SENTINEL=$(UPSTREAM_DIR)/R/galaxy_ie.R

# These must produce the image the tool XML asks for
# (<container type="docker">quay.io/galaxy/miadash-gxit:latest</container>),
# otherwise Galaxy pulls the old published image from the registry instead of
# using the image you just built locally.
docker_name=miadash-gxit
docker_repo=quay.io/galaxy
# Must match <port> in gxit/interactivetool_miadash.xml and ARG PORT in the
# Dockerfile.
internal_port=8080
# Host port : container port. The container only ever listens on internal_port,
# so publishing that same port keeps one number for everything. Change the host
# side (e.g. 9000:$(internal_port)) if 8080 is taken locally.
port=-p 127.0.0.1:$(internal_port):$(internal_port)
WEB_TAG=1.0.0
WEB_TARGET=${docker_repo}/${docker_name}:${WEB_TAG}
WEB_LATEST=${docker_repo}/${docker_name}:latest

re:clean docker

# Shallow clone of the app for the tests to read, outside the build tree. The
# Dockerfile never sees this.
.PHONY: deps
deps:
	@if [ -f "$(UPSTREAM_SENTINEL)" ]; then \
	    echo "== $(UPSTREAM_DIR) is already there"; \
	else \
	    echo "== cloning $(UPSTREAM_URL) @ $(UPSTREAM_REF) -> $(UPSTREAM_DIR)"; \
	    mkdir -p "$(DEPS_ROOT)/miadash" && \
	    git clone --depth 1 --branch "$(UPSTREAM_REF)" "$(UPSTREAM_URL)" "$(UPSTREAM_DIR)" && \
	    rm -rf "$(UPSTREAM_DIR)/.git"; \
	fi

# Always start from a fresh checkout - use it to pick up an app update.
.PHONY: refresh_deps
refresh_deps: clean_deps deps

.PHONY: clean_deps
clean_deps:
	@if [ -d "$(UPSTREAM_DIR)" ]; then \
	    echo "== removing $(UPSTREAM_DIR)"; \
	    rm -rf "$(UPSTREAM_DIR)"; \
	fi

push_hub: docker hub_login do_push remove_hub_credentials

do_push:
	docker push ${WEB_TARGET}
	docker push ${WEB_LATEST}

hub_login:
	if [ -n "$(DOCKERHUB_PASSWORD)" ]; then \
		printf '%s' "$(DOCKERHUB_PASSWORD)" | docker login --username=$(USERNAME) --password-stdin; \
	else \
		cat .password | docker login --username=$(USERNAME) --password-stdin; \
	fi

remove_hub_credentials:hub_logout

hub_logout:
	docker logout

docker_logout:
	docker logout

# The commit the branch currently points at. Passed as APP_REVISION so that a new
# app commit invalidates the clone layer: Docker caches a RUN layer on its
# command string and build args and cannot see that a git branch has moved, which
# is what made earlier rebuilds silently reuse a stale checkout.
app_revision ?= $(shell git ls-remote $(UPSTREAM_URL) $(UPSTREAM_REF) 2>/dev/null | cut -f1)

docker:
	@echo "== building $(docker_name):latest from $(UPSTREAM_REF) @ $(app_revision)"
	@docker build --build-arg PORT=${internal_port} \
	    --build-arg APP_REVISION=$(app_revision) \
	    -t $(docker_name):latest .
	@docker tag $(docker_name):latest ${WEB_TARGET}
	@docker tag $(docker_name):latest ${WEB_LATEST}

# Rebuild after new commits have been pushed to the app branch. Safe to run
# repeatedly: the dependency layer is reused, so only the clone and the app
# install are redone.
.PHONY: rebuild_app
rebuild_app:
	@$(MAKE) --no-print-directory docker

# standalone run, without Galaxy: the app is served on http://127.0.0.1:8080
it:
	docker run -it $(port) -e MIADASH_JOB_DIR=/tmp/miadash $(docker_name):latest

d:
	docker run -d $(port) -e MIADASH_JOB_DIR=/tmp/miadash $(docker_name):latest

sh:
	docker exec -i `docker ps --filter ancestor=$(docker_name):latest -q | head -1` bash

log:
	docker logs -f `docker ps --filter ancestor=$(docker_name):latest -q | head -1`

stop:
	docker stop `docker ps --filter ancestor=$(docker_name):latest -q | head -1`

# headless check of the R stack, the app object, the Galaxy wiring and the
# staged-input import - run it after an app update before trusting the image.
# The fixtures give R/galaxy_input.R something real to build a TreeSE from.
smoke:
	docker run --rm -v "$(CURDIR)/tests:/tests:ro" --entrypoint Rscript $(docker_name):latest --vanilla /tests/smoke_test.R

# input handling of the entry point: the staged files have to be reported in the
# startup log and exported to the app, and untouched inputs have to be reported
# as absent. Runs the real entry point with MIADASH_STARTUP_ONLY, no Shiny.
startup-test:
	@rm -rf "$(CURDIR)/.startup-job" && mkdir -p "$(CURDIR)/.startup-job/miadash_inputs"
	@cp "$(CURDIR)/tests/fixtures/assay.tsv" "$(CURDIR)/.startup-job/miadash_inputs/assay.tsv"
	@cp "$(CURDIR)/tests/fixtures/coldata.tsv" "$(CURDIR)/.startup-job/miadash_inputs/coldata.tsv"
	@log=$$(docker run --rm \
	    -v "$(CURDIR)/.startup-job:/job" \
	    -e MIADASH_JOB_DIR=/job -e MIADASH_STARTUP_ONLY=1 \
	    $(docker_name):latest 2>&1); \
	echo "$$log" | grep -q "miaDash Galaxy Interactive Tool" \
	    && echo "PASS - the startup log is written" \
	    || { echo "FAIL - no startup log"; echo "$$log"; exit 1; }; \
	echo "$$log" | grep -Eq "abundance table: +/job/miadash_inputs/assay.tsv \(" \
	    && echo "PASS - the staged abundance table is reported and exported" \
	    || { echo "FAIL - the abundance table was not staged"; echo "$$log"; exit 1; }; \
	echo "$$log" | grep -Eq "sample data: +/job/miadash_inputs/coldata.tsv \(" \
	    && echo "PASS - the staged colData is reported and exported" \
	    || { echo "FAIL - the colData was not staged"; echo "$$log"; exit 1; }; \
	echo "$$log" | grep -Eq "taxa data: +<not provided" \
	    && echo "PASS - an untouched optional input is reported as absent" \
	    || { echo "FAIL - missing input not reported"; echo "$$log"; exit 1; }; \
	echo "$$log" | grep -Eq "taxa tree: +<not provided" \
	    && echo "PASS - the untouched tree is reported as absent" \
	    || { echo "FAIL - missing tree not reported"; echo "$$log"; exit 1; }; \
	echo "$$log" | grep -q "Galaxy API key: missing" \
	    && echo "PASS - Galaxy session state is reported" \
	    || { echo "FAIL - Galaxy session state missing"; echo "$$log"; exit 1; }; \
	test -s "$(CURDIR)/.startup-job/miadash_startup.txt" \
	    && echo "PASS - the startup log is written to the file, not only to stdout" \
	    || { echo "FAIL - no startup log file"; exit 1; }; \
	rm -rf "$(CURDIR)/.startup-job"

# everything that can be checked without starting the app
test-fast: smoke startup-test

# is the app actually answering on the published port?
# Polled rather than slept on: loading the iSEE/mia stack plus the app's own
# libraries takes a while, and a fixed sleep would report a false failure (or
# hide a real one) depending on how warm the docker layer cache is.
check:
	docker run --rm -d --name miadash-check $(port) -e MIADASH_JOB_DIR=/tmp/miadash $(docker_name):latest
	@for i in $$(seq 1 60); do \
	    if curl -sSf -o /dev/null http://127.0.0.1:$(internal_port)/ 2>/dev/null; then \
	        echo "GET / -> HTTP 200 after $$((i * 5))s"; \
	        ok=1; break; \
	    fi; \
	    if ! docker ps --format '{{.Names}}' | grep -qx miadash-check; then \
	        echo "the container exited before answering"; break; \
	    fi; \
	    sleep 5; \
	done; \
	if [ -z "$$ok" ]; then echo "FAILED: no answer on port $(internal_port)"; fi; \
	docker logs miadash-check 2>&1 | tail -20; \
	docker rm -f miadash-check > /dev/null; \
	test -n "$$ok"

clean:
	docker kill `docker ps --filter ancestor=$(docker_name):latest -q` || true
	docker container prune
	docker rmi $(docker_name):latest || true

.PHONY: rebuild_app deps refresh_deps clean_deps docker it d sh log stop smoke startup-test test-fast check clean push_hub do_push hub_login remove_hub_credentials hub_logout docker_logout
