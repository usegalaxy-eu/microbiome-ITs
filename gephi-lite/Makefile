# Gephi Lite is used exactly as upstream publishes it: the image is
# phunudes/gephi-lite (built by the app's own GitLab CI), and our Dockerfile
# only resets the ENTRYPOINT so Galaxy's job script can run the app. There is
# no fork and no app code in this build tree.
UPSTREAM_IMAGE=gephi/gephi-lite
# Must match ARG APP_VERSION in the Dockerfile and the version in
# gxit/interactivetool_gephi-lite.xml.
upstream_version=latest

# These must produce the image the tool XML asks for
# (<container type="docker">quay.io/galaxy/gephi-lite-gxit:1.0.0</container>).
docker_name=gephi-lite-gxit
docker_repo=quay.io/galaxy
# Must match <port> in gxit/interactivetool_gephi-lite.xml (upstream's default).
internal_port=80
port=-p 127.0.0.1:$(internal_port):$(internal_port)
WEB_TAG=1.0.0
WEB_TARGET=${docker_repo}/${docker_name}:${WEB_TAG}
WEB_LATEST=${docker_repo}/${docker_name}:latest

re:clean docker

docker:
	@echo "== building $(docker_name):latest from $(UPSTREAM_IMAGE):$(upstream_version)"
	@docker build --build-arg APP_VERSION=$(upstream_version) -t $(docker_name):latest .
	@docker tag $(docker_name):latest ${WEB_TARGET}
	@docker tag $(docker_name):latest ${WEB_LATEST}

# standalone run, without Galaxy: the app is served on http://127.0.0.1:80
it:
	docker run -it $(port) $(docker_name):latest

d:
	docker run -d $(port) --name gephi-lite-dev $(docker_name):latest

sh:
	docker exec -i `docker ps --filter ancestor=$(docker_name):latest -q | head -1` bash

log:
	docker logs -f `docker ps --filter ancestor=$(docker_name):latest -q | head -1`

stop:
	docker stop `docker ps --filter ancestor=$(docker_name):latest -q | head -1`

# is the app actually answering on the published port?
check:
	docker run --rm -d --name gephi-lite-check $(port) $(docker_name):latest
	@for i in $$(seq 1 20); do \
	    if curl -sSf -o /dev/null http://127.0.0.1:$(internal_port)/ 2>/dev/null; then \
	        echo "GET / -> HTTP 200 after $$((i * 3))s"; \
	        ok=1; break; \
	    fi; \
	    if ! docker ps --format '{{.Names}}' | grep -qx gephi-lite-check; then \
	        echo "the container exited before answering"; break; \
	    fi; \
	    sleep 3; \
	done; \
	if [ -z "$$ok" ]; then echo "FAILED: no answer on port $(internal_port)"; fi; \
	docker logs gephi-lite-check 2>&1 | tail -20; \
	docker rm -f gephi-lite-check > /dev/null; \
	test -n "$$ok"

clean:
	docker kill `docker ps --filter ancestor=$(docker_name):latest -q` || true
	docker container prune
	docker rmi $(docker_name):latest || true

.PHONY: re docker it d sh log stop check clean
