# MicrobiomeProfiler is not vendored: the upstream repository is cloned into the
# build tree on demand (see the `deps` target) and never committed.
UPSTREAM_URL=https://github.com/yulab-smu/microbiomeprofiler
# `main` is an almost empty stub (LICENSE only); the package lives on `devel`, which
# is also the repository default branch.
UPSTREAM_REF=devel
UPSTREAM_DIR=MicrobiomeProfiler
UPSTREAM_SENTINEL=$(UPSTREAM_DIR)/DESCRIPTION

# These must produce the image the tool XML asks for
# (<container type="docker">paulzierep/microbiomeprofiler-gxit:latest</container>),
# otherwise Galaxy pulls the old published image from the registry instead of
# using the image you just built locally.
docker_name=microbiomeprofiler-gxit
docker_repo=paulzierep
# Must match <port> in gxit/interactivetool_microbiomeprofiler.xml and ARG PORT
# in the Dockerfile.
internal_port=8080
# Host port : container port. The container only ever listens on internal_port,
# so publishing that same port keeps one number for everything. Change the host
# side (e.g. 9000:$(internal_port)) if 8080 is taken locally.
port=-p 127.0.0.1:$(internal_port):$(internal_port)
WEB_TAG=1.0.0
WEB_TARGET=${docker_repo}/${docker_name}:${WEB_TAG}
WEB_LATEST=${docker_repo}/${docker_name}:latest

re:clean clean_deps docker

# Shallow clone of the upstream package, checked in as a build input only.
.PHONY: deps
deps:
	@if [ -f "$(UPSTREAM_SENTINEL)" ]; then \
	    echo "== $(UPSTREAM_DIR) is already there"; \
	else \
	    echo "== cloning $(UPSTREAM_URL) @ $(UPSTREAM_REF)"; \
	    rm -rf "$(UPSTREAM_DIR)" && \
	    git clone --depth 1 --branch "$(UPSTREAM_REF)" "$(UPSTREAM_URL)" "$(UPSTREAM_DIR)" && \
	    rm -rf "$(UPSTREAM_DIR)/.git"; \
	fi

# Always start from a fresh checkout - use it to pick up an upstream update.
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

docker: deps
	@docker build --build-arg PORT=${internal_port} -t $(docker_name):latest .
	@docker tag $(docker_name):latest ${WEB_TARGET}
	@docker tag $(docker_name):latest ${WEB_LATEST}

# standalone run, without Galaxy: the app is served on http://127.0.0.1:8080
it:
	docker run -it $(port) $(docker_name):latest

d:
	docker run -d $(port) $(docker_name):latest

sh:
	docker exec -i `docker ps -q --filter ancestor=$(docker_name):latest | head -1` bash

log:
	docker logs -f `docker ps -q --filter ancestor=$(docker_name):latest | head -1`

stop:
	docker stop `docker ps -q --filter ancestor=$(docker_name):latest | head -1`

# is the app actually answering on the published port?
# Polled rather than slept on: loading the clusterProfiler stack takes a while,
# and a fixed sleep would report a false failure (or hide a real one).
check:
	docker run --rm -d --name microbiomeprofiler-check $(port) $(docker_name):latest
	@for i in $$(seq 1 60); do \
	    if curl -sSf -o /dev/null http://127.0.0.1:$(internal_port)/ 2>/dev/null; then \
	        echo "GET / -> HTTP 200 after $$((i * 5))s"; \
	        ok=1; break; \
	    fi; \
	    if ! docker ps --format '{{.Names}}' | grep -qx microbiomeprofiler-check; then \
	        echo "the container exited before answering"; break; \
	    fi; \
	    sleep 5; \
	done; \
	if [ -z "$$ok" ]; then echo "FAILED: no answer on port $(internal_port)"; fi; \
	docker logs microbiomeprofiler-check 2>&1 | tail -20; \
	docker rm -f microbiomeprofiler-check > /dev/null; \
	test -n "$$ok"

clean:
	docker kill `docker ps -q --filter ancestor=$(docker_name):latest` || true
	docker container prune
	docker rmi $(docker_name):latest || true

.PHONY: deps refresh_deps clean_deps docker it d sh log stop check clean push_hub do_push hub_login remove_hub_credentials hub_logout docker_logout