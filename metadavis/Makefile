# MetaDAVis is not vendored: the app is cloned into the build tree on demand
# (see the `deps` target) and never committed.
#
# The default is the fork's `galaxy-input` branch, which adds the "Galaxy input"
# format (OTU table + taxonomy + metadata) to the application. Override both
# variables to build plain upstream, e.g.
#   make refresh_deps docker UPSTREAM_URL=https://github.com/GudaLab/MetaDAVis UPSTREAM_REF=main
UPSTREAM_URL=https://github.com/paulzierep/MetaDAVis
UPSTREAM_REF=galaxy-input
UPSTREAM_DIR=MetaDAVis
UPSTREAM_SENTINEL=$(UPSTREAM_DIR)/scripts/MaAsLin3.R

# These must produce the image the tool XML asks for
# (<container type="docker">paulzierep/metadavis-gxit:latest</container>), otherwise
# Galaxy pulls the old published image from the registry instead of using the
# image you just built locally.
docker_name=metadavis-gxit
docker_repo=paulzierep
# Must match <port> in gxit/interactivetool_metadavis.xml and ARG PORT in the
# Dockerfile.
internal_port=8080
# Host port : container port. The container only ever listens on
# internal_port, so publishing that same port keeps one number for everything.
# Change the host side (e.g. 9000:$(internal_port)) if 8080 is taken locally.
port=-p 127.0.0.1:$(internal_port):$(internal_port)
WEB_TAG=1.0.0
WEB_TARGET=${docker_repo}/${docker_name}:${WEB_TAG}
WEB_LATEST=${docker_repo}/${docker_name}:latest

re:clean clean_deps docker

# Shallow clone of the upstream app, checked in as a build input only. Written
# as a .PHONY target rather than a file target so that a half-deleted or stale
# checkout is repaired instead of being taken at face value.
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

# Same as deps, but always starts from a fresh checkout - use it to pick up an
# upstream update (or a different UPSTREAM_REF).
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
	docker run -it $(port) -e METADAVIS_JOB_DIR=/tmp/metadavis $(docker_name):latest

d:
	docker run -d $(port) -e METADAVIS_JOB_DIR=/tmp/metadavis $(docker_name):latest

# headless check of the R stack, the bundled example data and the Galaxy input
# staging shim - run it after an upstream update before trusting the image
smoke:
	docker run --rm -v "$(CURDIR)/tests:/tests:ro" --entrypoint Rscript $(docker_name):latest /tests/smoke_test.R

# focused test of the phyloseq (OTU + taxonomy + metadata) input path, without
# booting the Shiny app
test-phyloseq:
	docker run --rm -v "$(CURDIR)/MetaDAVis:/app:ro" -v "$(CURDIR)/tests:/tests:ro" \
	    --entrypoint Rscript $(docker_name):latest --vanilla /tests/phyloseq_test.R /tests/data

# is the app actually answering on the published port?
# Polled rather than slept on: loading ~40 R packages plus patching server.R
# takes a while, and a fixed sleep would report a false failure (or hide a real
# one) depending on how warm the docker layer cache is.
check:
	docker run --rm -d --name metadavis-check $(port) -e METADAVIS_JOB_DIR=/tmp/metadavis $(docker_name):latest
	@for i in $$(seq 1 60); do \
	    if curl -sSf -o /dev/null http://127.0.0.1:$(internal_port)/ 2>/dev/null; then \
	        echo "GET / -> HTTP 200 after $$((i * 5))s"; \
	        ok=1; break; \
	    fi; \
	    if ! docker ps --format '{{.Names}}' | grep -qx metadavis-check; then \
	        echo "the container exited before answering"; break; \
	    fi; \
	    sleep 5; \
	done; \
	if [ -z "$$ok" ]; then echo "FAILED: no answer on port $(internal_port)"; fi; \
	docker logs metadavis-check 2>&1 | tail -20; \
	docker rm -f metadavis-check > /dev/null; \
	test -n "$$ok"

sh:
	docker exec -i `docker ps -q --filter ancestor=$(docker_name):latest | head -1` bash

log:
	docker logs -f `docker ps -q --filter ancestor=$(docker_name):latest | head -1`

stop:
	docker stop `docker ps -q --filter ancestor=$(docker_name):latest | head -1`

clean:
	docker kill `docker ps -q --filter ancestor=$(docker_name):latest` || true
	docker container prune
	docker rmi $(docker_name):latest || true

.PHONY: deps refresh_deps clean_deps docker it d smoke test-phyloseq check sh log stop clean push_hub do_push hub_login remove_hub_credentials hub_logout docker_logout